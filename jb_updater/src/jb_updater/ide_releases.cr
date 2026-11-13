require "http/client"
require "json"
require "./http_client"
require "./logger"
require "./utils"

module JBUpdater
  # A single IDE release entry returned by the JetBrains releases API.
  struct IDERelease
    # Version string (e.g. `"2025.2"`).
    getter version : String
    # Release channel (`"release"`, `"eap"`, etc.).
    getter channel : String
    # Release date string.
    getter date : String
    # Download URL (with CDN host override applied).
    getter link : URI
    # URL of the `.sha256` checksum file, if the API provided one.
    getter checksum_link : URI?
    # Expected file size in bytes, if the API provided one.
    getter size : Int64?

    # @param version [String] Version string
    # @param channel [String] Release channel
    # @param date [String] Release date
    # @param link [URI] Download URL
    # @param checksum_link [URI?] Checksum file URL
    # @param size [Int64?] Expected size in bytes
    def initialize(@version : String, @channel : String, @date : String, @link : URI, @checksum_link : URI? = nil, @size : Int64? = nil)
    end
  end

  # Fetches and lists IDE releases from the JetBrains releases API.
  #
  # Queries `data.services.jetbrains.com/products/releases` and
  # returns structured {IDERelease} entries filtered by the target
  # platform and architecture.
  module IDEReleases
    extend self

    # Fetches IDE releases for a given product code.
    #
    # Supports filtering by channel, architecture, and recency.
    # Download URLs are automatically rewritten through
    # {HTTPClient.override_ide_repo_host}.
    #
    # @param product_code [String] Product code (e.g. `"RM"`, `"WS"`)
    # @param channel [String] Release channel (default `"release"`)
    # @param downloads_host [String?] Custom CDN host override
    # @param arch [String?] Target architecture (`"arm"` or `"intel"`); autodetected if nil
    # @param latest [Bool] Only latest per channel (default true)
    # @param platform [String?] Target OS (`"mac"`, `"linux"`, `"windows"`); autodetected if nil
    # @return [Array(IDERelease)] Available releases
    def fetch(
      product_code : String,
      channel : String = "release",
      downloads_host : String? = nil,
      arch : String? = nil,
      latest : Bool = true,
      platform : String? = nil,
    ) : Array(IDERelease)
      url = "https://data.services.jetbrains.com/products/releases" \
            "?code=#{Utils.escape(product_code)}" \
            "&latest=#{latest}" \
            "&type=#{Utils.escape(channel)}"

      Log.info("IDEReleases: GET #{url}")

      res = HTTPClient.head_or_get(url)
      unless res.status_code == 200
        raise "IDEReleases: HTTP #{res.status_code} for #{url}"
      end

      body = res.body || raise "empty response body"
      data = JSON.parse(body)

      arr = extract_releases_arr(data, product_code)

      if arr.nil? || arr.empty?
        raise "IDEReleases: no releases found for product code '#{product_code}' " \
              "(check the --product value or configured product code)"
      end

      releases = [] of IDERelease

      arch_to_use = (arch || autodetect_arch)
      platform_to_use = (platform || autodetect_platform)

      arr.each do |release|
        parsed = parse_release(release, arch_to_use, platform_to_use, channel, downloads_host)
        releases << parsed if parsed
      end

      releases
    end

    # Parses a single release entry from the JetBrains Releases API JSON.
    private def parse_release(
      release : JSON::Any,
      arch_to_use : String,
      platform_to_use : String,
      channel : String,
      downloads_host : String?,
    ) : IDERelease?
      ver = release["version"].as_s
      ch = release["channel"]?.try(&.as_s) || channel
      dt = release["date"]?.try(&.as_s) || ""

      downloads_any = release["downloads"]?
      return unless downloads_any.is_a?(JSON::Any)

      downloads = downloads_any.as_h

      platform_key = platform_download_key(downloads, platform_to_use, arch_to_use)
      return unless platform_key && downloads[platform_key]?

      entry = downloads[platform_key].as_h
      link_any = entry["link"]?
      return unless link_any

      uri = URI.parse(link_any.as_s)
      uri = HTTPClient.override_ide_repo_host(uri, downloads_host)

      checksum_link = entry["checksumLink"]?.try(&.as_s?).try { |raw| URI.parse(raw) }
      checksum_link = checksum_link.try { |link| HTTPClient.override_ide_repo_host(link, downloads_host) }
      size = entry["size"]?.try(&.as_i64?)

      IDERelease.new(version: ver, channel: ch, date: dt, link: uri, checksum_link: checksum_link, size: size)
    end

    # Selects the downloads-map key for the current platform and CPU arch.
    #
    # Prefers ARM64 variants when available, falls back to the base key.
    #
    # @param downloads [Hash(String, JSON::Any)] Release downloads map
    # @param platform [String] `"mac"`, `"linux"`, or `"windows"`
    # @param arch [String] `"arm"` or `"intel"`
    # @return [String?] Downloads key, or `nil` for unknown platforms
    private def platform_download_key(
      downloads : Hash(String, JSON::Any),
      platform : String,
      arch : String,
    ) : String?
      case platform
      when "mac", "darwin"
        arch == "arm" && downloads["macM1"]? ? "macM1" : "mac"
      when "linux"
        arch == "arm" && downloads["linuxARM64"]? ? "linuxARM64" : "linux"
      when "windows", "win32"
        arch == "arm" && downloads["windowsARM64"]? ? "windowsARM64" : "windows"
      end
    end

    # Detects the current OS platform.
    #
    # @return [String] `"mac"`, `"linux"`, or `"windows"`
    private def autodetect_platform : String
      {% if flag?(:darwin) %}
        "mac"
      {% elsif flag?(:win32) %}
        "windows"
      {% else %}
        "linux"
      {% end %}
    end

    # Detects the CPU architecture by running `uname -m`.
    #
    # @return [String] `"arm"` or `"intel"`
    private def autodetect_arch : String
      io = IO::Memory.new
      status = Process.run("uname", args: ["-m"], output: io)
      machine = io.to_s.strip
      if status.success?
        case machine
        when "arm64", "aarch64" then "arm"
        else                         "intel"
        end
      else
        "intel"
      end
    rescue
      "intel"
    end

    # Extracts the releases array from the JetBrains Releases API response.
    #
    # The API normally maps the requested product code to an array, but
    # occasionally returns the array under a *variant* key (for example
    # `"IIU"` for code `"IU"`). The exact code key wins; otherwise the
    # first array-valued entry of the response is used.
    #
    # @param data [JSON::Any] Parsed API response object
    # @param product_code [String] Requested product code (e.g. `"IU"`)
    # @return [Array(JSON::Any)?] Releases array, or `nil` when absent
    def extract_releases_arr(data : JSON::Any, product_code : String) : Array(JSON::Any)?
      if exact = data[product_code]?
        exact.as_a?
      else
        data.as_h.values.compact_map(&.as_a?).first?
      end
    end
  end
end
