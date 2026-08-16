require "http/client"
require "file_utils"
require "./http_client"
require "./utils"
require "./logger"

module JBUpdater
  # Handles JetBrains IDE downloads and upgrades.
  #
  # Supports two modes:
  # - **Direct**: downloads the latest IDE DMG for manual installation.
  # - **Homebrew patch**: rewrites the download URL in a local Homebrew
  #   cask file so `brew upgrade` uses the CDN mirror.
  class IDEUpdater
    getter opts : Options

    # @param opts [Options] CLI options
    def initialize(@opts : Options)
    end

    # Runs the IDE upgrade process.
    #
    # Resolves the product name (from `--product` or guessed from
    # `--ide-path`), fetches the latest download URL, applies the
    # CDN host override, and performs either a direct download or
    # a Homebrew cask patch.
    def run : Nil
      if opts.product.nil?
        if p = opts.ide_path
          guessed = File.basename(p).sub(/\.app$/, "")
          opts.product = guessed
          Log.info("Guessed product name: #{guessed}")
        else
          Log.fail("Missing --product <Name> (e.g., RubyMine2025.2)")
          exit 1
        end
      end

      product = opts.product || raise "product not set"
      build_url = latest_ide_download_url(product)
      final_uri = HTTPClient.override_ide_repo_host(build_url, opts.ide_downloads_host)

      if opts.dry_run?
        Log.header("Dry run — no files will be downloaded or modified")
        Log.info("Would download: #{final_uri}")
        Log.info("Mode: #{opts.brew_patch ? "Homebrew cask patch" : "direct DMG download"}")
        return
      end

      if opts.brew_patch
        patch_homebrew_cask(product, final_uri)
      else
        upgrade_direct(product, final_uri)
      end
    end

    # Fetches the latest IDE download URL from the JetBrains releases API.
    #
    # Queries `data.services.jetbrains.com/products/releases` and selects
    # the architecture-appropriate download link (Apple Silicon or Intel).
    #
    # @param product [String] Product name (e.g. `"RubyMine2025.2"`)
    # @return [URI] Direct download URL for the latest version
    private def latest_ide_download_url(product : String) : URI
      product_code = infer_product_code(product)
      url = "https://data.services.jetbrains.com/products/releases?code=#{Utils.escape(product_code)}&latest=true&type=release"
      Log.info("Fetching latest release for #{product_code}")

      res = HTTPClient.head_or_get(url)
      if res.status_code != 200
        raise "JetBrains releases API returned #{res.status_code}"
      end

      body = res.body || raise "empty response body"
      data = JSON.parse(body)

      releases = IDEReleases.extract_releases_arr(data, product_code)
      release = releases.try(&.first?)
      raise "No downloads found for product code '#{product_code}'" unless release

      version = release["version"].as_s
      downloads = release["downloads"]

      platform_key = download_key_for(platform, opts.arch)

      entry = downloads[platform_key]? || raise "No download entry found for platform '#{platform}' (#{platform_key}) for #{product_code}"
      link = entry["link"].as_s

      dmg_url = link
      Log.success("Latest version #{version}")
      URI.parse(dmg_url)
    end

    # Determines the current OS platform.
    #
    # @return [String] `"mac"`, `"linux"`, or `"windows"`
    private def platform : String
      {% if flag?(:darwin) %}
        "mac"
      {% elsif flag?(:linux) %}
        "linux"
      {% elsif flag?(:win32) %}
        "windows"
      {% else %}
        raise "Unsupported OS"
      {% end %}
    end

    # Maps platform + architecture to the JetBrains releases API download key.
    #
    # - **mac** (Apple Silicon): `macM1`; otherwise: `mac`
    # - **linux** (ARM64): `linuxARM64`; otherwise: `linux`
    # - **windows**: `windows`
    #
    # @param platform [String] OS platform (`"mac"`, `"linux"`, `"windows"`)
    # @param arch [String?] Architecture (`"arm"` or `"intel"`); autodetected if nil
    # @return [String] Download key in the JetBrains releases API payload
    private def download_key_for(platform : String, arch : String?) : String
      cpu = arch || autodetect_arch
      case platform
      when "mac"
        cpu == "arm" ? "macM1" : "mac"
      when "linux"
        cpu == "arm" ? "linuxARM64" : "linux"
      else
        "windows"
      end
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

    # Maps a product name to its JetBrains product code.
    #
    # Delegates to {JBUpdater.Utils.product_code} (case-insensitive).
    #
    # @param product [String] Product name (e.g. `"PhpStorm2025.1"` or `"phpstorm"`)
    # @return [String] Product code (e.g. `"PS"`)
    private def infer_product_code(product : String) : String
      Utils.product_code(product)
    end

    # ------------------------------------------------------------------------
    # Direct installation

    # Downloads the IDE DMG to a temporary directory.
    #
    # The user must mount and install the DMG manually.
    #
    # @param product [String] Product name (for logging)
    # @param uri [URI] Download URL (with CDN override already applied)
    private def upgrade_direct(product : String, uri : URI) : Nil
      ext = case platform
            when "mac"     then ".dmg"
            when "windows" then ".exe"
            else                ".tar.gz"
            end
      dmg_path = File.join(Dir.tempdir, "upgrade-#{product}-#{Time.utc.to_unix}#{ext}")

      if opts.dry_run?
        Log.warn("Dry run: would download #{uri} to #{dmg_path}")
        return
      end

      cdn_uri = uri

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

    # Overrides `download.jetbrains.com` host with `download-cdn.jetbrains.com`.
    #
    # @param uri [URI] Original download URI
    # @return [URI] URI with CDN host (unchanged if not a JetBrains download)
    private def override_ide_repo_host(uri : URI) : URI
      if uri.host =~ /^download\.jetbrains\.com$/i
        URI.new(scheme: "https", host: "download-cdn.jetbrains.com", path: uri.path, query: uri.query)
      else
        uri
      end
    end

    # ------------------------------------------------------------------------
    # Homebrew patch mode

    # Patches a Homebrew cask file to use the CDN mirror URL.
    #
    # Locates the cask file in the Homebrew taps directory and
    # replaces its `url` value with the resolved download URI.
    #
    # @param product [String] Product name (used to derive cask filename)
    # @param uri [URI] CDN download URL
    private def patch_homebrew_cask(product : String, uri : URI) : Nil
      cask_name = "#{product.strip.downcase}.rb"

      tap_paths = [
        "/opt/homebrew/Library/Taps/homebrew/homebrew-cask/Casks",
        "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-cask/Casks",
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

      if opts.dry_run?
        Log.warn("Dry run: would patch #{cask_path}")
        Log.info("Replacing cask url with: #{uri}")
        return
      end

      File.write(cask_path, new_content)

      Log.success("Patched cask: #{cask_path}")
      Log.info("Now run: brew upgrade #{product.downcase}")
    end

    # Returns the expected Homebrew cask filename for a product.
    #
    # @param product [String] Product name
    # @return [String] e.g. `"rubymine.rb"`
    private def cask_filename(product : String) : String
      name = product.strip.downcase
      "#{name}.rb"
    end
  end
end
