#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'net/http'
require 'uri'
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'rexml/document'
require 'cgi'
require 'digest'
require 'json'

module JBUpdater
  INF = 1.0 / 0.0
  PRODUCT_BIN = {
    'RubyMine' => 'rubymine',
    'IntelliJIdea' => 'idea',
    'IntelliJIdeaCE' => 'idea',
    'PyCharm' => 'pycharm',
    'PyCharmCE' => 'pycharm',
    'WebStorm' => 'webstorm',
    'GoLand' => 'goland',
    'CLion' => 'clion',
    'DataGrip' => 'datagrip',
    'PhpStorm' => 'phpstorm',
    'Rider' => 'rider',
    'AppCode' => 'appcode'
  }.freeze

  PRODUCT_APP = {
    'IntelliJIdea' => 'IntelliJ IDEA',
    'IntelliJIdeaCE' => 'IntelliJ IDEA CE',
    'PyCharm' => 'PyCharm',
    'PyCharmCE' => 'PyCharm CE',
    # Others use the same name
    'RubyMine' => 'RubyMine',
    'WebStorm' => 'WebStorm',
    'GoLand' => 'GoLand',
    'CLion' => 'CLion',
    'DataGrip' => 'DataGrip',
    'PhpStorm' => 'PhpStorm',
    'Rider' => 'Rider',
    'AppCode' => 'AppCode'
  }.freeze

  PRODUCT_CODE_GUESS = {
    "IntelliJ IDEA Ultimate": 'IU',
    "IntelliJ IDEA Community": 'IC',
    "IntelliJ IDEA Educational": 'IE',
    PhpStorm: 'PS',
    WebStorm: 'WS',
    "PyCharm Professional": 'PY',
    "PyCharm Community": 'PC',
    "PyCharm Educational": 'PE',
    RubyMine: 'RM',
    AppCode: 'OC',
    CLion: 'CL',
    GoLand: 'GO',
    DataGrip: 'DB',
    Rider: 'RD',
    "Android Studio": 'AI',
    RustRover: 'RR',
    Aqua: 'QA'
  }.freeze

  class Runner
    def initialize(opts = {})
      @opts = {
        plugins_dir: nil,
        build: nil,
        only: [],
        only_incompatible: false,
        dry_run: false,
        downloads_host: nil, # e.g. "downloads.marketplace.jetbrains.com"
        pin_versions: {}, # xmlId => version
        direct_urls: {}, # xmlId => https://.../files/...zip
        list: false,
        bin_path: nil # path to IDE executable (Linux/macOS override)
      }.merge(opts.transform_keys!(&:to_sym))
      @build = @opts[:build]
      @installed_plugins = nil
    end

    attr_reader :opts, :build

    def run(action = nil)
      validate!
      @build ||= detect_build_from_path
      raise 'Could not detect IDE build; pass opts[:build] or --build' unless @build

      case action || (@opts[:list] ? :list : :update)
      when :list then list_plugins
      when :update then update_plugins
      else raise "Unknown action: #{action}"
      end
    end

    # -------------------------
    # Listing and updating (unchanged from your version)
    # -------------------------
    def list_plugins
      plugins = installed_plugins
      if plugins.empty?
        puts "No plugins found in #{opts[:plugins_dir]}"
        return
      end
      id_w = plugins.keys.map(&:length).max
      ver_w = plugins.values.map { |m| (m['version'] || '').length }.max
      puts "Installed plugins for build #{build}:"
      plugins.each do |pid, meta|
        ver = meta['version'] || 'unknown'
        since = meta['since'] || ''
        untl = meta['until'] || ''
        status = build_in_range?(build, since, untl) ? 'OK' : 'incompatible'
        printf("- %-#{id_w}s  %-#{ver_w}s  [since=%-10s until=%-10s]  %s\n",
               pid, ver, since.empty? ? '-' : since, untl.empty? ? '-' : untl, status)
      end
    end

    def update_plugins
      candidates = filter_targets(installed_plugins)
      if candidates.empty?
        puts "No matching plugins to update in #{opts[:plugins_dir]}"
        return
      end

      puts "Build: #{build}"
      puts "Checking #{candidates.size} plugin(s)"

      candidates.each do |xml_id, meta|
        current_ver = meta['version'] || 'unknown'
        target_dir = meta['path']

        begin
          final_uri =
            if opts[:direct_urls][xml_id]
              URI(opts[:direct_urls][xml_id])
            elsif (ver = opts[:pin_versions][xml_id])
              resolve_download_url_for_version(xml_id, ver)
            else
              resolve_download_url_via_plugin_manager(xml_id, build)
            end

          final_uri = rewrite_to_downloads_host(final_uri, opts[:downloads_host])

          want_ver = opts[:pin_versions][xml_id] || File.basename(final_uri.path).sub(/\.zip\z/, '').split('-').last

          puts "[#{xml_id}] #{current_ver} -> #{want_ver || '?'}"
          puts "  URL: #{final_uri}"

          if opts[:dry_run]
            puts "  (dry-run) would download and install into #{target_dir}"
            next
          end

          tmp_zip = File.join(Dir.tmpdir, "jb-#{safe(xml_id)}-#{Time.now.to_i}.zip")
          begin
            http_download(final_uri, tmp_zip)
            extract_zip_install(tmp_zip, target_dir)
            post_id, post_ver, post_since, post_until = parse_plugin_meta_from_dir(target_dir)
            compat = build_in_range?(build, post_since, post_until)
            puts "  installed: #{post_id} #{post_ver} [since=#{post_since || '-'} until=#{post_until || '-'}] #{compat ? '' : '(still incompatible!)'}"
          ensure
            FileUtils.rm_f(tmp_zip)
          end
        rescue StandardError => e
          warn "[#{xml_id}] failed: #{e}"
        end
      end

      puts 'Done. Start the IDE to load updated plugins.'
    end

    # -------------------------
    # Build detection (refactored)
    # -------------------------
    def detect_build_from_path
      os = Gem::Platform.local.os # 'darwin', 'linux', 'mingw32', etc.
      case os
      when 'darwin' then detect_build_macos
      when 'linux' then detect_build_linux
      else
        detect_build_via_binary(opts[:bin_path] || which_any(default_bin_candidates))
      end
    end

    def detect_build_macos
      # 1) Figure out which product from plugins_dir (e.g., "RubyMine2025.2" -> "RubyMine")
      base = product_base_from_plugins_dir
      # 2) If user provided a binary path, prefer it
      return detect_build_via_binary(opts[:bin_path]) if opts[:bin_path] && File.executable?(opts[:bin_path])

      # 3) Try to locate the .app bundle and read product-info.json/build.txt (no launch)
      app_path = mac_find_app_bundle(base)
      if app_path
        from_info = build_from_app_bundle(app_path)
        return from_info if from_info

        # fallback to the binary inside .app
        bin = File.join(app_path, 'Contents', 'MacOS', mac_bin_name_for(base))
        return detect_build_via_binary(bin) if File.executable?(bin)
      end
      detect_build_via_binary(which_any(mac_path_bin_candidates(base)))
    end

    def detect_build_linux
      # Prefer explicit bin_path
      return detect_build_via_binary(opts[:bin_path]) if opts[:bin_path] && File.executable?(opts[:bin_path])

      base = product_base_from_plugins_dir
      # Try PATH
      bin = which_any(linux_path_bin_candidates(base))
      return detect_build_via_binary(bin) if bin

      # Try Toolbox scripts (~/.local/share/JetBrains/Toolbox/scripts/<bin>)
      tbox = File.join(Dir.home, '.local', 'share', 'JetBrains', 'Toolbox', 'scripts', linux_bin_name_for(base))
      detect_build_via_binary(tbox) if File.executable?(tbox)
    end

    def detect_build_via_binary(bin)
      return nil unless bin && File.executable?(bin)

      out, _st = run_cmd(bin, '--version')
      # Matches "Build #RM-252.23892.415" (or IU/IC/WS/etc)
      if out =~ /Build\s+#([A-Z]{2})-(\d+\.\d+\.\d+)/
        "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}"
      elsif out =~ /Build\s+#([A-Z]{2}-\S+)/
        Regexp.last_match(1)
      end
    end

    # Read product-info.json and/or build.txt for build number + product code, avoiding launching the app.
    def build_from_app_bundle(app_path)
      info = File.join(app_path, 'Contents', 'Resources', 'product-info.json')
      if File.file?(info)
        begin
          j = JSON.parse(File.read(info, encoding: 'UTF-8'))
          code = j['productCode'] || j['productCodeName'] || j['product']&.[]('code')
          build = j['buildNumber'] || j['build'] || j['version']
          return "#{code}-#{build}" if code && build
        rescue JSON::ParserError
          # ignore; fall through to build.txt
        end
      end
      build_txt = File.join(app_path, 'Contents', 'Resources', 'build.txt')
      if File.file?(build_txt)
        bn = File.read(build_txt, encoding: 'UTF-8').strip
        # Try to guess product code from app name if we can
        code = PRODUCT_CODE_GUESS[product_base_from_plugins_dir]
        return "#{code}-#{bn}" unless bn.empty?
      end
      nil
    end

    # -------------------------
    # macOS: product/app/bin helpers
    # -------------------------
    def product_base_from_plugins_dir
      # ".../JetBrains/RubyMine2025.2/plugins" => "RubyMine2025.2"
      parent = File.basename(File.dirname(opts[:plugins_dir]))
      # strip trailing version numbers and separators
      parent.sub(/\d.*\z/, '')
    end

    def mac_bin_name_for(base) = PRODUCT_BIN[base] || base.downcase

    def linux_bin_name_for(base) = PRODUCT_BIN[base] || base.downcase

    def mac_app_names_for(base)
      app = PRODUCT_APP[base] || base
      # Try exact app name and a wildcard (to catch " EAP" or version suffixes)
      [app, "#{app}*"]
    end

    def mac_search_paths
      [
        '/Applications',
        File.join(Dir.home, 'Applications'),
        '/Applications/JetBrains Toolbox',
        File.join(Dir.home, 'Applications', 'JetBrains Toolbox')
      ].uniq
    end

    def mac_find_app_bundle(base)
      mac_app_names_for(base).each do |name|
        mac_search_paths.each do |dir|
          Dir.glob(File.join(dir, "#{name}.app")).each do |app|
            return app if File.directory?(app)
          end
        end
      end
      nil
    end

    def mac_path_bin_candidates(base)
      bin = mac_bin_name_for(base)
      cands = []
      mac_app_names_for(base).each do |name|
        mac_search_paths.each do |dir|
          Dir.glob(File.join(dir, "#{name}.app", 'Contents', 'MacOS', bin)).each do |path|
            cands << path
          end
        end
      end
      # Plus anything on PATH named after the bin (Toolbox adds shims)
      cands << which(bin)
      cands.compact.uniq
    end

    # -------------------------
    # Linux helpers
    # -------------------------
    def linux_path_bin_candidates(base)
      bin = linux_bin_name_for(base)
      cands = []
      cands << which(bin)
      cands << "/usr/bin/#{bin}" if File.executable?("/usr/bin/#{bin}")
      cands << File.join(Dir.home, '.local', 'share', 'JetBrains', 'Toolbox', 'scripts', bin)
      cands.compact.uniq
    end

    # -------------------------
    # Common helpers
    # -------------------------
    def which(cmd)
      out, st = Open3.capture2e('which', cmd)
      st.success? ? out.strip : nil
    end

    def which_any(cands)
      Array(cands).find { |p| p && File.executable?(p) }
    end

    def default_bin_candidates
      %w[rubymine idea webstorm pycharm clion datagrip goland phpstorm rider]
        .map { |b| which(b) }.compact
    end

    # -------------------------
    # Plugin scanning (unchanged)
    # -------------------------
    def installed_plugins
      @installed_plugins ||= begin
                               result = {}
                               Dir.children(opts[:plugins_dir]).sort.each do |entry|
                                 next if entry.start_with?('.')

                                 path = File.join(opts[:plugins_dir], entry)
                                 next unless File.directory?(path)

                                 id, ver, since, untl = parse_plugin_meta_from_dir(path)
                                 next unless id

                                 result[id] =
                                   { 'version' => ver, 'path' => path, 'folder' => entry, 'since' => since,
                                     'until' => untl }
                               end
                               result
                             end
    end

    private

    def validate!
      raise 'opts[:plugins_dir] is required' unless opts[:plugins_dir]
      raise "Plugins dir not found: #{opts[:plugins_dir]}" unless Dir.exist?(opts[:plugins_dir])
      raise "'unzip' not found in PATH" unless unzip_available?
    end

    def filter_targets(plugins)
      filtered = plugins.dup
      unless (only = Array(opts[:only])).empty?
        filtered.select! { |k, _| only.include?(k) }
      end
      if opts[:only_incompatible]
        filtered.reject! do |_, meta|
          build_in_range?(build, meta['since'], meta['until'])
        end
      end
      filtered
    end

    def unzip_available?
      system('which', 'unzip', out: File::NULL, err: File::NULL)
    end

    def safe(s)
      s.to_s.gsub(/[^\w.-]/, '_')
    end

    def run_cmd(cmd, *args)
      Open3.capture2e(cmd, *args)
    end

    def read_text_from_jar(jar_path, inner_path)
      out, st = run_cmd('unzip', '-p', jar_path, inner_path)
      st.success? ? out : nil
    rescue Errno::ENOENT
      nil
    end

    def parse_plugin_xml(xml)
      doc = REXML::Document.new(xml)
      id = REXML::XPath.first(doc, '//id')&.text&.strip
      version = REXML::XPath.first(doc, '//version')&.text&.strip
      id ||= REXML::XPath.first(doc, '//name')&.text&.strip # older plugins
      iv = REXML::XPath.first(doc, '//idea-version')
      since = iv&.attributes&.[]('since-build') || iv&.attributes&.[]('sinceBuild')
      untl = iv&.attributes&.[]('until-build') || iv&.attributes&.[]('untilBuild')
      [id, version, since, untl]
    rescue REXML::ParseException
      [nil, nil, nil, nil]
    end

    def parse_plugin_meta_from_dir(plugin_dir)
      xml_path = File.join(plugin_dir, 'META-INF', 'plugin.xml')
      if File.file?(xml_path)
        xml = File.read(xml_path, encoding: 'UTF-8')
        id, ver, since, untl = parse_plugin_xml(xml)
        return [id, ver, since, untl] if id
      end
      Dir.glob(File.join(plugin_dir, 'lib', '*.jar')).each do |jar|
        xml = read_text_from_jar(jar, 'META-INF/plugin.xml')
        next unless xml && !xml.empty?

        id, ver, since, untl = parse_plugin_xml(xml)
        return [id, ver, since, untl] if id
      end
      [nil, nil, nil, nil]
    end

    def parse_build_string(str)
      return nil if str.nil? || str.empty?

      core = str.sub(/\A[A-Z]+-/, '')
      parts = core.split('.', 3)
      parts.map! { |p| p == '*' ? INF : p.to_i }
      parts.fill(0, parts.length...3)
    end

    def build_in_range?(build_str, since_str, until_str)
      b = parse_build_string(build_str)
      s = since_str && !since_str.empty? ? parse_build_string(since_str) : [0, 0, 0]
      u = until_str && !until_str.empty? ? parse_build_string(until_str) : [INF, INF, INF]
      ((s <=> b) <= 0) && ((b <=> u) <= 0)
    end

    def http_head_or_get(url, method: :get)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        req = method == :head ? Net::HTTP::Head.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
        req['User-Agent'] = 'jb-updater/1.3 (+ruby)'
        http.request(req)
      end
    end

    def resolve_download_url_via_plugin_manager(xml_id, bld)
      base = "https://plugins.jetbrains.com/pluginManager?action=download&id=#{CGI.escape(xml_id)}&build=#{CGI.escape(bld)}"
      res = http_head_or_get(base, method: :get)
      case res
      when Net::HTTPRedirection
        loc = res['location'] or raise 'Missing Location header from pluginManager'
        loc_uri = URI.parse(loc)
        loc_uri.absolute? ? loc_uri : URI.join('https://plugins.jetbrains.com', loc)
      when Net::HTTPSuccess
        URI(base)
      else
        raise "pluginManager failed (HTTP #{res.code}) for #{xml_id} build #{bld}"
      end
    end

    def resolve_download_url_for_version(xml_id, version)
      base = "https://plugins.jetbrains.com/plugin/download?pluginId=#{CGI.escape(xml_id)}&version=#{CGI.escape(version)}"
      res = http_head_or_get(base, method: :get)
      case res
      when Net::HTTPRedirection
        loc = res['location'] or raise 'Missing Location header'
        loc_uri = URI.parse(loc)
        loc_uri.absolute? ? loc_uri : URI.join('https://plugins.jetbrains.com', loc)
      when Net::HTTPSuccess
        URI(base)
      else
        raise "version download resolve failed (HTTP #{res.code}) for #{xml_id}@#{version}"
      end
    end

    def rewrite_to_downloads_host(uri, downloads_host)
      return uri unless downloads_host && !downloads_host.empty?

      if uri.host =~ /\Aplugins\.jetbrains\.com\z/i && uri.path.start_with?('/files/')
        URI::HTTPS.build(host: downloads_host, path: uri.path, query: uri.query)
      else
        uri
      end
    end

    def http_download(uri, dest_path)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        req = Net::HTTP::Get.new(uri.request_uri)
        req['User-Agent'] = 'jb-updater/1.3 (+ruby)'
        http.request(req) do |res|
          case res
          when Net::HTTPSuccess
            File.open(dest_path, 'wb') { |f| res.read_body { |chunk| f.write(chunk) } }
          when Net::HTTPRedirection
            next_uri = URI(res['location'])
            next_uri = URI.join("#{uri.scheme}://#{uri.host}", res['location']) unless next_uri.absolute?
            return http_download(next_uri, dest_path)
          else
            raise "HTTP #{res.code} #{res.message} for #{uri}"
          end
        end
      end
    end

    def extract_zip_install(zip_path, dest_dir)
      Dir.mktmpdir('jb-plg-') do |tmp|
        ok = system('unzip', '-qq', '-o', zip_path, '-d', tmp)
        raise "unzip failed for #{zip_path}" unless ok

        entries = Dir.children(tmp).reject { |e| e == '__MACOSX' }
        root = tmp
        if entries.size == 1
          candidate = File.join(tmp, entries.first)
          root = candidate if File.directory?(candidate)
        end
        if File.exist?(dest_dir)
          backup = "#{dest_dir}.bak.#{Time.now.to_i}"
          FileUtils.mv(dest_dir, backup)
          puts "Backed up: #{dest_dir} -> #{backup}"
        end
        FileUtils.mkdir_p(File.dirname(dest_dir))
        FileUtils.mv(root, dest_dir)
      end
      true
    end
  end
end

# ----------------------------
# CLI wrapper
# ----------------------------
if __FILE__ == $PROGRAM_NAME
  cli_opts = {
    pin_versions: {},
    direct_urls: {}
  }
  OptionParser.new do |o|
    o.banner = 'Usage: ruby jb_updater.rb --plugins-dir DIR [--build BUILD] [options]'
    o.on('--plugins-dir DIR', 'Path to .../JetBrains/<ProductYYYY.X>/plugins') { |v| cli_opts[:plugins_dir] = v }
    o.on('--build BUILD', 'IDE build, e.g. RM-252.23892.415 (auto-detect if omitted)') { |v| cli_opts[:build] = v }
    o.on('--bin-path PATH', 'Path to IDE executable (Linux/macOS override)') { |v| cli_opts[:bin_path] = v }
    o.on('--only IDS', Array, 'CSV of xmlIds to update (default: all installed)') { |v| cli_opts[:only] = v }
    o.on('--only-incompatible', 'Limit to plugins incompatible with current build') do
      cli_opts[:only_incompatible] = true
    end
    o.on('--downloads-host HOST', 'Rewrite /files/ host to this (e.g. downloads.marketplace.jetbrains.com)') do |v|
      cli_opts[:downloads_host] = v
    end
    o.on('--pin PAIR', 'Pin xmlId=version (can repeat)') do |v|
      id, ver = v.split('=', 2)
      cli_opts[:pin_versions][id] = ver if id && ver
    end
    o.on('--direct PAIR', 'Use direct URL for xmlId: xmlId=https://... (can repeat)') do |v|
      id, url = v.split('=', 2)
      cli_opts[:direct_urls][id] = url if id && url
    end
    o.on('--dry-run', 'Show actions without downloading/installing') { cli_opts[:dry_run] = true }
    o.on('--list', 'List installed plugins with compatibility status and exit') { cli_opts[:list] = true }
    o.on('-h', '--help', 'Show help') do
      puts o
      exit 0
    end
  end.parse!

  updater = JBUpdater::Runner.new(cli_opts)
  updater.run
end
