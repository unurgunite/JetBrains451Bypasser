require "http/client"
require "file_utils"
require "./http_client"
require "./utils"
require "./logger"

module JBUpdater
  class IDEUpdater
    getter opts : Options

    def initialize(@opts : Options)
    end

    def run : Nil
      if opts.product.nil?
        Log.fail("Missing --product <Name> (e.g., RubyMine2025.2)")
        exit 1
      end

      product = opts.product.not_nil!
      build_url = latest_ide_download_url(product)
      final_uri = HTTPClient.override_plugin_repo_host(build_url, "download-cdn.jetbrains.com")

      if opts.brew_patch
        patch_homebrew_cask(product, final_uri)
      else
        upgrade_direct(product, final_uri)
      end
    end

    # ------------------------------------------------------------------------

    private def latest_ide_download_url(product : String) : URI
      # Example JetBrains API endpoint:
      # https://data.services.jetbrains.com/products/releases?code=RM&latest=true&type=release
      product_code = infer_product_code(product)
      url = "https://data.services.jetbrains.com/products/releases?code=#{Utils.escape(product_code)}&latest=true&type=release"
      Log.info("Fetching latest release for #{product_code}")

      res = HTTPClient.head_or_get(url)
      if res.status_code != 200
        raise "JetBrains releases API returned #{res.status_code}"
      end

      data = JSON.parse(res.body.not_nil!)
      version = data[product_code][0]["version"].as_s
      downloads = data[product_code][0]["downloads"]
      link = nil

      arch = opts.arch || autodetect_arch

      if arch == "arm" && downloads["macM1"]?
        link = downloads["macM1"]["link"].as_s
      else
        link = downloads["mac"]["link"].as_s
      end

      dmg_url = link
      Log.success("Latest version #{version}")
      URI.parse(dmg_url)
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

    private def infer_product_code(product : String) : String
      # crude mapping; extend as needed
      {
        "RubyMine" => "RM",
        "WebStorm" => "WS",
        "PyCharm"  => "PY",
        "CLion"    => "CL",
        "GoLand"   => "GO",
      }[product.gsub(/\d+.*/, "")] || product[0, 2].upcase
    end

    # ------------------------------------------------------------------------
    # Direct installation

    private def upgrade_direct(product : String, uri : URI) : Nil
      dmg_path = File.join(Dir.tempdir, "upgrade-#{product}-#{Time.utc.to_unix}.dmg")

      # Replace JetBrains direct host with CDN mirror
      cdn_uri = override_ide_repo_host(uri)

      Log.header("Downloading #{product} from #{cdn_uri.host}…")
      begin
        HTTPClient.download(cdn_uri, dmg_path)
        Log.success("Downloaded to #{dmg_path}")
        Log.info("Mount the DMG and drag the new app into /Applications manually")
      rescue ex
        Log.fail("Download failed: #{ex.message}")
        Log.info("Tip: try again with CDN mirror (--upgrade-ide automatically uses it)")
      end
    end

    private def override_ide_repo_host(uri : URI) : URI
      if uri.host =~ /^download\.jetbrains\.com$/i
        URI.new(scheme: "https", host: "download-cdn.jetbrains.com", path: uri.path, query: uri.query)
      else
        uri
      end
    end

    # ------------------------------------------------------------------------
    # Homebrew patch mode

    private def patch_homebrew_cask(product : String, uri : URI) : Nil
      cask_name = "#{product.strip.downcase}.rb"

      # Common Homebrew tap paths
      tap_paths = [
        "/opt/homebrew/Library/Taps/homebrew/homebrew-cask/Casks",       # Apple Silicon default
        "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-cask/Casks", # Intel default
      ]

      cask_path = tap_paths
        .map { |root| File.join(root, cask_name) }
        .find { |path| File.exists?(path) }

      unless cask_path
        Log.fail("Could not find #{cask_name} in Homebrew taps:\n  #{tap_paths.join("\n  ")}")
        Log.info("Note: files under /opt/homebrew/Caskroom/.../.metadata are backups, not active casks.")
        exit 1
      end

      content = File.read(cask_path)
      new_content = content.gsub(/url\s+["'].*["']/, %(url "#{uri}"))
      File.write(cask_path, new_content)

      Log.success("Patched cask: #{cask_path}")
      Log.info("Now run: brew upgrade #{product.downcase}")
    end

    private def cask_filename(product : String) : String
      name = product.strip.downcase
      "#{name}.rb"
    end
  end
end
