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

  class Updater
    getter opts : Options
    property build : String?
    @installed_plugins : Hash(String, PluginMeta)? = nil

    def initialize(@opts : Options)
      @build = @opts.build
    end

    def run(action : Symbol? = nil) : Nil
      validate!

      @build ||= detect_build_info
      raise "Could not detect IDE build; pass --build" unless @build

      act = action || begin
        if @opts.list
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

    private def detect_build_info : String?
      base_name = File.basename(File.dirname(@opts.plugins_dir.not_nil!)).gsub(/\d.*$/, "")
      info_json = ""
      build_txt = ""

      # Prefer explicit --ide-path
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

    private def validate!
      raise "plugins_dir required" unless @opts.plugins_dir
      raise "Plugins dir not found: #{@opts.plugins_dir}" unless Dir.exists?(@opts.plugins_dir.not_nil!)
    end

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

    private def installed_plugins : Hash(String, PluginMeta)
      return @installed_plugins.not_nil! if @installed_plugins

      @installed_plugins = PluginMeta.scan_dir(@opts.plugins_dir.not_nil!)
    end

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

          dest = File.join(@opts.plugins_dir.not_nil!, xml_id)
          backup = "#{dest}.bak.#{Time.utc.to_unix}"

          if File.directory?(dest)
            FileUtils.mv(dest, backup)
            Log.info("#{plugin_num} Backed up: #{dest} → #{backup}")
          end

          tmp_zip = File.join(Dir.tempdir, "jb-#{Utils.safe(xml_id)}-#{Time.utc.to_unix}.zip")
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

    private def update_plugin(meta : PluginMeta) : Nil
      xml_id = meta.id
      target_dir = meta.path
      current_ver = meta.version
      tmp_zip : String? = nil

      begin
        uri = final_uri(xml_id)
        uri = HTTPClient.override_plugin_repo_host(uri, @opts.downloads_host)
        want_ver = @opts.pin_versions[xml_id]? ||
                   File.basename(uri.path).sub(/\.zip$/, "").split('-').last?

        Log.info "  → #{current_ver} → #{want_ver || "?"}"
        Log.info "    URL: #{uri}"

        if @opts.dry_run
          Log.info "    (dry-run) would download and install into #{target_dir}"
          return
        end

        tmp_zip = File.join(Dir.tempdir, "jb-#{Utils.safe(xml_id)}-#{Time.utc.to_unix}.zip")
        HTTPClient.download(uri, tmp_zip)
        Utils.extract_zip(tmp_zip, target_dir)

        if post = PluginMeta.parse_from_dir(target_dir)
          compat = Utils.build_in_range?(@build.not_nil!, post.since, post.until_build)
          suffix = compat ? "" : " (still incompatible)"
          Log.success "  installed: #{post.id} #{post.version} [since=#{post.since || "-"} until=#{post.until_build || "-"}]#{suffix}"
        else
          Log.warn "  re-parse failed; installed plugin may be broken"
        end
      ensure
        FileUtils.rm_rf(tmp_zip) if tmp_zip && File.exists?(tmp_zip)
      end
    end

    # --- URL-resolution helpers ----------------------------------------------

    private def final_uri(xml_id : String) : URI
      if @opts.direct_urls.has_key?(xml_id)
        URI.parse(@opts.direct_urls[xml_id])
      elsif ver = @opts.pin_versions[xml_id]?
        resolve_download_url_for_version(xml_id, ver)
      else
        resolve_download_url_via_plugin_manager(xml_id, @build.not_nil!)
      end
    end

    private def resolve_download_url_for_version(xml_id : String, version : String) : URI
      base = "https://plugins.jetbrains.com/plugin/download?pluginId=#{Utils.escape(xml_id)}&version=#{Utils.escape(version)}"
      res = HTTPClient.head_or_get(base)
      case res.status_code
      when 301, 302
        loc = res.headers["Location"]?
        raise "Missing Location header" unless loc
        loc_uri = URI.parse(loc)
        loc_uri.absolute? ? loc_uri : URI.parse("https://plugins.jetbrains.com#{loc}")
      when 200
        URI.parse(base)
      else
        raise "version download resolve failed (HTTP #{res.status_code}) for #{xml_id}@#{version}"
      end
    end

    private def resolve_download_url_via_plugin_manager(xml_id : String, build : String) : URI
      base = "https://plugins.jetbrains.com/pluginManager?action=download&id=#{Utils.escape(xml_id)}&build=#{Utils.escape(build)}"
      res = HTTPClient.head_or_get(base)
      case res.status_code
      when 301, 302
        loc = res.headers["Location"]?
        raise "Missing Location header from pluginManager" unless loc
        loc_uri = URI.parse(loc)
        loc_uri.absolute? ? loc_uri : URI.parse("https://plugins.jetbrains.com#{loc}")
      when 200
        URI.parse(base)
      else
        raise "pluginManager failed (HTTP #{res.status_code}) for #{xml_id} build #{build}"
      end
    end
  end
end
