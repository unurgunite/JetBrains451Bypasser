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

      @build ||= detect_build_info_macos
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

    private def validate!
      raise "plugins_dir required" unless @opts.plugins_dir
      raise "Plugins dir not found: #{@opts.plugins_dir}" unless Dir.exists?(@opts.plugins_dir.not_nil!)
    end

    private def detect_build_info_macos : String?
      base = File.basename(File.dirname(@opts.plugins_dir.not_nil!)).gsub(/\d.*$/, "")
      app_path = "/Applications/#{base}.app"
      info_json = File.join(app_path, "Contents", "Resources", "product-info.json")
      build_txt = File.join(app_path, "Contents", "Resources", "build.txt")

      if File.file?(info_json)
        data = JSON.parse(File.read(info_json))

        code =
          data["productCode"]?.try(&.as_s?) ||
            data["product"]?.try(&.[]("code")).try(&.as_s?)

        build =
          data["buildNumber"]?.try(&.as_s?) ||
            data["build"]?.try(&.as_s?) ||
            data["version"]?.try(&.as_s?)

        return "#{code}-#{build}" if code && build
      elsif File.file?(build_txt)
        build = File.read(build_txt).strip
        return "RM-#{build}" unless build.empty?
      end

      nil
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

        # Re-parse plugin.xml in the freshly extracted directory
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

    # Determine the correct download URL for a given plugin id
    private def final_uri(xml_id : String) : URI
      if @opts.direct_urls.has_key?(xml_id)
        URI.parse(@opts.direct_urls[xml_id])
      elsif ver = @opts.pin_versions[xml_id]?
        resolve_download_url_for_version(xml_id, ver)
      else
        resolve_download_url_via_plugin_manager(xml_id, @build.not_nil!)
      end
    end

    # Resolve URL for a specific pinned version
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

    # Resolve URL for the latest compatible version via pluginManager
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
