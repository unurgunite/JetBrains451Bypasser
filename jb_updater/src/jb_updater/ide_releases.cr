require "http/client"
require "json"
require "./http_client"
require "./logger"
require "./utils"

module JBUpdater
  struct IDERelease
    getter version : String
    getter channel : String
    getter date : String
    getter link : URI

    def initialize(@version : String, @channel : String, @date : String, @link : URI)
    end
  end

  module IDEReleases
    extend self

    # product_code examples:
    #   "WS" for WebStorm, "RM" for RubyMine, etc.
    # channel: "release" | "eap" | ...
    # latest: true -> only latest per channel, false -> full history
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

      data = JSON.parse(res.body.not_nil!)
      arr = data[product_code]?.try &.as_a?
      raise "IDEReleases: unexpected JSON for #{product_code}" unless arr && !arr.empty?

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
            # no mac build for this release; skip
            next
          end

        platform = downloads[platform_key].as_h
        link_any = platform["link"]?
        next unless link_any

        link_s = link_any.as_s
        uri = URI.parse(link_s)

        # Apply IDE host override (download.jetbrains.com → download-cdn.jetbrains.com or custom)
        uri = HTTPClient.override_ide_repo_host(uri, downloads_host)

        releases << IDERelease.new(version: ver, channel: ch, date: dt, link: uri)
      end

      releases
    end

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
