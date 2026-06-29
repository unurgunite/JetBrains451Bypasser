require "http/client"
require "json"
require "xml"
require "file_utils"
require "option_parser"
require "uri"
require "digest"
require "./logger"
require "./utils"
require "./plugin_meta"
require "./http_client"

module JBUpdater
  INF = Float64::INFINITY

  # Core plugin update orchestrator.
  #
  # Handles listing installed plugins, installing new plugins
  # and checking for/ applying updates. Resolves download URLs
  # via the JetBrains Plugin Manager API and supports pinned
  # versions, direct URLs, and host overrides.
  class Updater
    getter opts : Options
    # Detected or explicitly provided build string (e.g. `"RM-252"`).
    property build : String?
    @installed_plugins : Hash(String, PluginMeta)? = nil

    # @param opts [Options] CLI options
    def initialize(@opts : Options)
      @build = @opts.build
    end

    # Runs the updater with an optional action symbol.
    #
    # Determines the action from options if not provided:
    # - `:list`    — list installed plugins
    # - `:install` — install plugins by ID
    # - `:update`  — update all installed plugins (default)
    #
    # @param action [Symbol?] One of `:list`, `:install`, `:update`
    def run(action : Symbol? = nil) : Nil
      validate!

      @build ||= detect_build_info
      raise "Could not detect IDE build; pass --build" unless @build

      act = action || begin
        if @opts.list?
          :list
        elsif !@opts.install_ids.empty?
          :install
        else
          :update
        end
      end

      case act
      when :list
        list_plugins
      when :install
        install_plugins
      when :update
        update_plugins
      else
        raise "Unknown action: #{act}"
      end
    end

    # Attempts to auto-detect the IDE build string from metadata files.
    #
    # Checks `--ide-path` first, then common install locations
    # (`/Applications/*.app` on macOS, `/opt/*` on Linux, etc.).
    # Reads from `product-info.json` or `build.txt`.
    #
    # @return [String?] Detected build string or `nil`
    private def detect_build_info : String?
      plugins_dir = @opts.plugins_dir
      return nil unless plugins_dir
      base_name = File.basename(File.dirname(plugins_dir)).gsub(/\d.*$/, "")
      info_json = ""
      build_txt = ""

      if custom = @opts.ide_path
        {% if flag?(:darwin) %}
          info_json, build_txt = ide_metadata_paths(:mac, custom)
        {% elsif flag?(:linux) %}
          info_json, build_txt = ide_metadata_paths(:linux, custom)
        {% elsif flag?(:win32) %}
          info_json, build_txt = ide_metadata_paths(:windows, custom)
        {% else %}
          raise "Unsupported platform"
        {% end %}
        if result = read_build_info(info_json, build_txt, File.basename(custom))
          return result
        end
      end

      candidates = [] of String
      {% if flag?(:darwin) %}
        candidates = ["/Applications/#{base_name}.app"]
      {% elsif flag?(:linux) %}
        candidates = ["/opt/#{base_name}", "/usr/share/#{base_name}", "/snap/#{base_name}/current"]
      {% elsif flag?(:win32) %}
        roots = [
          ENV["LOCALAPPDATA"]?,
          ENV["PROGRAMFILES"]?,
          ENV["PROGRAMFILES(X86)"]?,
        ].compact
        candidates = roots.map { |r| File.join(r, "JetBrains", base_name) }
      {% else %}
        raise "Unsupported platform"
      {% end %}

      candidates.each do |root|
        {% if flag?(:darwin) %}
          info_json, build_txt = ide_metadata_paths(:mac, root)
        {% elsif flag?(:linux) %}
          info_json, build_txt = ide_metadata_paths(:linux, root)
        {% elsif flag?(:win32) %}
          info_json, build_txt = ide_metadata_paths(:windows, root)
        {% end %}
        if result = read_build_info(info_json, build_txt, base_name)
          return result
        end
      end

      JBUpdater::Log.warn("Could not detect build for #{base_name}")
      nil
    end

    # Returns platform-specific paths for IDE metadata files.
    #
    # @param platform [:mac | :linux | :windows] Target platform
    # @param root [String] IDE installation root
    # @return [Tuple(String, String)] `(product-info.json path, build.txt path)`
    private def ide_metadata_paths(platform, root : String) : {String, String}
      case platform
      when :mac
        {
          File.join(root, "Contents", "Resources", "product-info.json"),
          File.join(root, "Contents", "Resources", "build.txt"),
        }
      else
        {
          File.join(root, "bin", "product-info.json"),
          File.join(root, "build.txt"),
        }
      end
    end

    # Attempts to read build info from `product-info.json` or `build.txt`.
    #
    # @param info_json [String] Path to `product-info.json`
    # @param build_txt [String] Path to `build.txt`
    # @param base_name [String] Fallback product base name
    # @return [String?] Build string (e.g. `"RM-252"`) or `nil`
    private def read_build_info(info_json : String, build_txt : String, base_name : String) : String?
      if File.file?(info_json)
        begin
          data = JSON.parse(File.read(info_json))
          code =
            data["productCode"]?.try(&.as_s?) ||
              data["product"]?.try(&.[]("code")).try(&.as_s?)
          build =
            data["buildNumber"]?.try(&.as_s?) ||
              data["build"]?.try(&.as_s?) ||
              data["version"]?.try(&.as_s?)
          return "#{code}-#{build}" if code && build
        rescue ex
          JBUpdater::Log.warn("Parse error in #{info_json}: #{ex.message}")
        end
      elsif File.file?(build_txt)
        build = File.read(build_txt).strip
        return "#{base_name}-#{build}" unless build.empty?
      end
      nil
    end

    # Validates that the plugins directory exists and expands tildes.
    private def validate!
      if dir = @opts.plugins_dir
        dir = Utils.expand_tilde(dir)
        @opts.plugins_dir = dir
        raise "Plugins dir not found: #{dir}" unless Dir.exists?(dir)
      else
        raise "plugins_dir required"
      end
    end

    # Prints the list of installed plugins to stdout.
    private def list_plugins : Nil
      plugins = installed_plugins
      if plugins.empty?
        puts "No plugins found in #{@opts.plugins_dir}"
        return
      end
      puts "Installed plugins:"
      plugins.each_value do |meta|
        puts "- #{meta.id} #{meta.version}"
      end
    end

    # Scans the plugins directory for installed plugins (cached).
    #
    # @return [Hash(String, PluginMeta)] Plugin ID to metadata mapping
    private def installed_plugins : Hash(String, PluginMeta)
      if plugins = @installed_plugins
        return plugins
      end
      dir = @opts.plugins_dir
      raise "plugins_dir not set" unless dir
      @installed_plugins = PluginMeta.scan_dir(dir)
    end

    # Installs plugins by XML ID.
    #
    # Backs up existing plugin directories before overwriting.
    #
    # @raise [RuntimeError] If no plugin IDs provided
    private def install_plugins : Nil
      ids = @opts.install_ids
      if ids.empty?
        Log.warn("No plugin IDs provided to --install-plugin")
        return
      end

      Log.header("Installing #{ids.size} plugin#{ids.size > 1 ? "s" : ""} for build #{@build}")

      ids.each_with_index do |xml_id, idx|
        tmp_zip : String? = nil
        begin
          plugin_num = "[#{idx + 1}/#{ids.size}]"
          uri = final_uri(xml_id)
          uri = HTTPClient.override_plugin_repo_host(uri, @opts.downloads_host)

          Log.info("#{plugin_num} Resolved URL: #{uri}")
          dir = @opts.plugins_dir || raise "plugins_dir not set"
          dest = File.join(dir, xml_id)
          backup = "#{dest}.bak.#{Time.utc.to_unix}"

          if File.directory?(dest)
            FileUtils.mv(dest, backup)
            Log.info("#{plugin_num} Backed up: #{dest} → #{backup}")
          end

          tmp_zip = File.join(Dir.tempdir, "jb-#{Utils.safe(xml_id)}-#{Time.utc.to_unix}.zip")
          Log.info("#{plugin_num} Downloading #{xml_id} to #{tmp_zip}")
          HTTPClient.download(uri, tmp_zip)
          Utils.extract_zip(tmp_zip, dest)
          Log.success("#{plugin_num} #{xml_id} installed successfully")
        rescue ex
          Log.fail("[#{xml_id}] installation failed: #{ex.message}")
        ensure
          FileUtils.rm_rf(tmp_zip) if tmp_zip && File.exists?(tmp_zip)
        end
      end

      puts
      Log.success("Done. Start the IDE to load newly installed plugins.")
    end

    # Checks all installed plugins for updates and downloads newer versions.
    private def update_plugins : Nil
      plugins = installed_plugins
      if plugins.empty?
        Log.info "No plugins found in #{@opts.plugins_dir}"
        return
      end

      Log.header("Checking #{plugins.size} plugin#{plugins.size > 1 ? "s" : ""} for updates (build #{@build})")

      plugins.each_with_index do |(id, meta), idx|
        begin
          Log.info "[#{idx + 1}/#{plugins.size}] #{meta.id} current=#{meta.version}"
          update_plugin(meta)
        rescue ex
          Log.fail "[#{meta.id}] update failed: #{ex.message}"
        end
      end

      puts
      Log.success("Done. Start the IDE to load updated plugins.")
    end

    # Downloads and extracts the latest version of a single plugin.
    #
    # Checks compatibility range after installation and logs the result.
    #
    # @param meta [PluginMeta] Currently installed plugin metadata
    private def update_plugin(meta : PluginMeta) : Nil
      xml_id = meta.id
      target_dir = meta.path
      tmp_zip : String? = nil

      begin
        uri = final_uri(xml_id)
        uri = HTTPClient.override_plugin_repo_host(uri, @opts.downloads_host)

        Log.info "  → #{meta.version} → #{resolved_version(xml_id, uri)}"
        Log.info "    URL: #{uri}"

        if @opts.dry_run?
          Log.info "    (dry-run) would download and install into #{target_dir}"
          return
        end

        tmp_zip = File.join(Dir.tempdir, "jb-#{Utils.safe(xml_id)}-#{Time.utc.to_unix}.zip")
        HTTPClient.download(uri, tmp_zip)
        Utils.extract_zip(tmp_zip, target_dir)

        log_install_result(target_dir)
      ensure
        FileUtils.rm_rf(tmp_zip) if tmp_zip && File.exists?(tmp_zip)
      end
    end

    private def resolved_version(xml_id : String, uri : URI) : String
      @opts.pin_versions[xml_id]? ||
        File.basename(uri.path).sub(/\.zip$/, "").split('-').last? || "?"
    end

    private def log_install_result(target_dir : String)
      if post = PluginMeta.parse_from_dir(target_dir)
        since = post.since || "-"
        until_build = post.until_build || "-"
        compat = Utils.build_in_range?(@build || raise("build not set"), post.since, post.until_build)
        suffix = compat ? "" : " (still incompatible)"
        Log.success "  installed: #{post.id} #{post.version} [since=#{since} until=#{until_build}]#{suffix}"
      else
        Log.warn "  re-parse failed; installed plugin may be broken"
      end
    end

    # --- URL-resolution helpers ----------------------------------------------

    # Resolves the final download URI for a plugin XML ID.
    #
    # Priority: direct URL > pinned version > pluginManager API.
    #
    # @param xml_id [String] Plugin XML identifier
    # @return [URI] Download URL (may be a redirect endpoint)
    private def final_uri(xml_id : String) : URI
      if @opts.direct_urls.has_key?(xml_id)
        URI.parse(@opts.direct_urls[xml_id])
      elsif ver = @opts.pin_versions[xml_id]?
        resolve_download_url_for_version(xml_id, ver)
      else
        resolve_download_url_via_plugin_manager(xml_id, @build || raise("build not set"))
      end
    end

    # Resolves a download URL for a pinned plugin version.
    #
    # Performs a HEAD/GET request and follows redirects.
    #
    # @param xml_id [String] Plugin XML identifier
    # @param version [String] Desired version
    # @return [URI] Redirect target or direct URL
    private def resolve_download_url_for_version(xml_id : String, version : String) : URI
      base = "https://plugins.jetbrains.com/plugin/download?pluginId=#{Utils.escape(xml_id)}&version=#{Utils.escape(version)}"
      Log.info "Resolving download URL for #{xml_id} version #{version}: #{base}"
      res = HTTPClient.head_or_get(base)
      case res.status_code
      when 301, 302
        loc = res.headers["Location"]?
        raise "Missing Location header" unless loc
        loc_uri = URI.parse(loc)
        Log.info "Resolved #{xml_id}@#{version} → #{loc}"
        loc_uri.absolute? ? loc_uri : URI.parse("https://plugins.jetbrains.com#{loc}")
      when 200
        Log.info "Resolved #{xml_id}@#{version} → direct URL"
        URI.parse(base)
      else
        raise "version download resolve failed (HTTP #{res.status_code}) for #{xml_id}@#{version}"
      end
    end

    # Resolves a download URL via the JetBrains Plugin Manager API.
    #
    # Falls back to `plugin/download` if the build-specific endpoint
    # returns 404 (plugin incompatible with the given build).
    #
    # @param xml_id [String] Plugin XML identifier
    # @param build [String] IDE build string
    # @return [URI] Resolved download URL
    private def resolve_download_url_via_plugin_manager(xml_id : String, build : String) : URI
      base = "https://plugins.jetbrains.com/pluginManager?action=download&id=#{Utils.escape(xml_id)}&build=#{Utils.escape(build)}"
      Log.info "Resolving download URL via pluginManager: #{base}"
      res = HTTPClient.head_or_get(base)
      case res.status_code
      when 301, 302
        loc = res.headers["Location"]?
        raise "Missing Location header from pluginManager" unless loc
        loc_uri = URI.parse(loc)
        Log.info "pluginManager redirect for #{xml_id}: #{loc}"
        loc_uri.absolute? ? loc_uri : URI.parse("https://plugins.jetbrains.com#{loc}")
      when 200
        Log.info "pluginManager returned 200 for #{xml_id}, using direct URL"
        URI.parse(base)
      when 404
        Log.info "pluginManager 404 for #{xml_id} (incompatible with #{build}), trying plugin/download fallback..."
        fallback = "https://plugins.jetbrains.com/plugin/download?pluginId=#{Utils.escape(xml_id)}"
        res2 = HTTPClient.head_or_get(fallback)
        case res2.status_code
        when 301, 302
          loc = res2.headers["Location"]?
          raise "Missing Location header from plugin/download" unless loc
          loc_uri = URI.parse(loc)
          Log.info "plugin/download redirect for #{xml_id}: #{loc}"
          loc_uri.absolute? ? loc_uri : URI.parse("https://plugins.jetbrains.com#{loc}")
        when 200
          Log.info "plugin/download returned 200 for #{xml_id}, using direct URL"
          URI.parse(fallback)
        else
          raise "plugin not found for #{xml_id} (pluginManager 404, plugin/download #{res2.status_code})"
        end
      else
        raise "pluginManager failed (HTTP #{res.status_code}) for #{xml_id} build #{build}"
      end
    end
  end
end
