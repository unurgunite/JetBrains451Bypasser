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

    # @param version [String] Version string
    # @param channel [String] Release channel
    # @param date [String] Release date
    # @param link [URI] Download URL
    def initialize(@version : String, @channel : String, @date : String, @link : URI)
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
    # @return [Array(IDERelease)] Available releases
    def fetch(
      product_code : String,
      channel : String = "release",
      downloads_host : String? = nil,
      arch : String? = nil,
      latest : Bool = true,
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
      arr = data[product_code]?.try &.as_a?
      raise "IDEReleases: unexpected JSON for #{product_code}" if arr.nil? || arr.empty?

      releases = [] of IDERelease

      arch_to_use = (arch || autodetect_arch)

      arr.each do |release|
        ver = release["version"].as_s
        ch = release["channel"]?.try(&.as_s) || channel
        dt = release["date"]?.try(&.as_s) || ""

        downloads_any = release["downloads"]?
        next unless downloads_any.is_a?(JSON::Any)

        downloads = downloads_any.as_h

        platform_key =
          if arch_to_use == "arm" && downloads["macM1"]?
            "macM1"
          elsif downloads["mac"]?
            "mac"
          else
            next
          end

        platform = downloads[platform_key].as_h
        link_any = platform["link"]?
        next unless link_any

        link_s = link_any.as_s
        uri = URI.parse(link_s)

        uri = HTTPClient.override_ide_repo_host(uri, downloads_host)

        releases << IDERelease.new(version: ver, channel: ch, date: dt, link: uri)
      end

      releases
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
  end
end
