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

INF = 1.0 / 0.0

PRODUCT_CODE_GUESS = {
  'IntelliJ IDEA Ultimate' => 'IU',
  'IntelliJ IDEA Community' => 'IC',
  'IntelliJ IDEA Educational' => 'IE',
  'PhpStorm' => 'PS',
  'WebStorm' => 'WS',
  'PyCharm Professional' => 'PY',
  'PyCharm Community' => 'PC',
  'PyCharm Educational' => 'PE',
  'RubyMine' => 'RM',
  'AppCode' => 'OC',
  'CLion' => 'CL',
  'GoLand' => 'GO',
  'DataGrip' => 'DB',
  'Rider' => 'RD',
  'Android Studio' => 'AI',
  'RustRover' => 'RR',
  'Aqua' => 'QA'
}.freeze

# Map config base name (from ".../JetBrains/<BaseYYYY.X>/plugins") to display name used above
BASE_TO_DISPLAY = {
  'IntelliJIdea' => 'IntelliJ IDEA Ultimate',
  'IdeaIC' => 'IntelliJ IDEA Community',
  'IdeaIE' => 'IntelliJ IDEA Educational',

  'RubyMine' => 'RubyMine',
  'WebStorm' => 'WebStorm',
  'PhpStorm' => 'PhpStorm',

  'PyCharm' => 'PyCharm Professional',
  'PyCharmCE' => 'PyCharm Community',
  'PyCharmEdu' => 'PyCharm Educational',

  'CLion' => 'CLion',
  'GoLand' => 'GoLand',
  'DataGrip' => 'DataGrip',
  'Rider' => 'Rider',
  'AppCode' => 'AppCode',

  'AndroidStudio' => 'Android Studio',
  'RustRover' => 'RustRover',
  'Aqua' => 'Aqua'
}.freeze

# For locating .app bundles in /Applications
BASE_TO_APP = {
  'IntelliJIdea' => 'IntelliJ IDEA.app',
  'IdeaIC' => 'IntelliJ IDEA CE.app',
  'IdeaIE' => 'IntelliJ IDEA Educational.app',

  'RubyMine' => 'RubyMine.app',
  'WebStorm' => 'WebStorm.app',
  'PhpStorm' => 'PhpStorm.app',

  'PyCharm' => 'PyCharm.app',
  'PyCharmCE' => 'PyCharm CE.app',
  'PyCharmEdu' => 'PyCharm Educational.app',

  'CLion' => 'CLion.app',
  'GoLand' => 'GoLand.app',
  'DataGrip' => 'DataGrip.app',
  'Rider' => 'Rider.app',
  'AppCode' => 'AppCode.app',

  'AndroidStudio' => 'Android Studio.app',
  'RustRover' => 'RustRover.app',
  'Aqua' => 'Aqua.app'
}.freeze

# Mac .app inner binary names
BASE_TO_BIN = {
  'IntelliJIdea' => 'idea',
  'IdeaIC' => 'idea',
  'IdeaIE' => 'idea',

  'RubyMine' => 'rubymine',
  'WebStorm' => 'webstorm',
  'PhpStorm' => 'phpstorm',

  'PyCharm' => 'pycharm',
  'PyCharmCE' => 'pycharm',
  'PyCharmEdu' => 'pycharm',

  'CLion' => 'clion',
  'GoLand' => 'goland',
  'DataGrip' => 'datagrip',
  'Rider' => 'rider',
  'AppCode' => 'appcode',

  'AndroidStudio' => 'studio',
  'RustRover' => 'rustrover',
  'Aqua' => 'aqua'
}.freeze

class JBUpdater
  def initialize(opts = {})
    @opts = {
      plugins_dir: nil,
      build: nil,
      only: [],
      only_incompatible: false,
      dry_run: false,
      downloads_host: nil,
      pin_versions: {},
      direct_urls: {},
      list: false,
      bin_path: nil # optional override
    }.merge((opts || {}).transform_keys(&:to_sym))
    @build = @opts[:build]
    @installed_plugins = nil
  end

  attr_accessor :build
  attr_reader :opts

  def run(action = nil)
    validate!
    self.build ||= detect_build_info_macos
    raise 'Could not detect IDE build; pass --build' unless self.build

    case action || (opts[:list] ? :list : :update)
    when :list then list_plugins
    when :update then update_plugins
    else raise "Unknown action: #{action}"
    end
  end

  private

  # This method is used to validate the configuration
  #
  # @raise [OptionParser::MissingArgument] if opts[:plugins_dir] is not provided.
  # @return [nil] if the configuration is valid.
  def validate!
    raise OptionParser::MissingArgument, 'opts[:plugins_dir] is required' unless opts[:plugins_dir]
    return if Dir.exist?(opts[:plugins_dir])

    raise OptionParser::MissingArgument, "Plugins dir not found: #{opts[:plugins_dir]}"
  end

  # This method is used to detect the build of the IDE on macOS. It tries to detect which IDE is used in two ways:
  # 1) If an explicit bin is provided, try it first. That means that if the IDE was installed in a custom location, we
  #    can still detect the build by providing the path to the inner binary by running this binary with --version argument.
  # 2) Try reading product-info.json/build.txt from .app bundle (preferred). That means that if IDE was installed in a standard
  #    location, we can still detect the build by parsing build.txt from the .app bundle.
  #
  # @return [String] build info.
  # @return [nil] if product-info.json or build.txt not found or empty.
  # @see JBUpdater#get_build_info_with_cli
  # @see JBUpdater#ide_name_from_plugins_dir
  # @see JBUpdater#mac_find_app_bundle
  # @see JBUpdater#build_info_from_app_bundle
  def detect_build_info_macos
    # 1) If explicit bin provided, try it first
    if opts[:bin_path] && File.executable?(opts[:bin_path]) && (b = get_build_info_with_cli(opts[:bin_path]))
      return b
    end

    base = ide_name_from_plugins_dir
    raise 'Could not infer IDE name from plugins_dir' if base.nil? || base.empty?

    # 2) Try reading product-info.json/build.txt from .app bundle (preferred)
    return unless app_bundle_path
    if (b = build_info_from_app_bundle)
      return b
    end

    # Fallback: run the inner binary with --version
    bin = File.join(app_bundle_path, 'Contents', 'MacOS', BASE_TO_BIN[base] || base.downcase)
    return unless File.executable?(bin) && (b2 = get_build_info_with_cli(bin))

    b2
  end

  # This method is used to detect the build of the IDE on macOS. It runs the inner binary with --version argument.
  def get_build_info_with_cli(bin)
    return nil unless bin && File.executable?(bin)

    out, _st = run_cmd(bin, '--version')
    if out =~ /Build\s+#([A-Z]{2})-(\d+\.\d+\.\d+)/
      "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}"
    elsif out =~ /Build\s+#([A-Z]{2}-\S+)/
      Regexp.last_match(1)
    end
  end

  # This method is used to detect the build of the IDE on macOS.
  #
  # @example
  #   RM-252.23892.415
  # @return [String] build info.
  # @return [nil] if product-info.json or build.txt not found or empty.
  def build_info_from_app_bundle = info_from_product_info_json || info_from_build_txt

  # This method is used to detect the build of the IDE on macOS from product-info.json
  #
  # @example
  #   RM-252.23892.415
  # @return [String] build info.
  # @return [nil] if product-info.json not found or empty.
  def info_from_product_info_json
    info = File.join(app_bundle_path, 'Contents', 'Resources', 'product-info.json')
    return unless File.file?(info)

    begin
      j = JSON.parse(File.read(info, encoding: 'UTF-8'))
      code = j['productCode'] || j['product']&.[]('code')
      build = j['buildNumber'] || j['build'] || j['version']
      "#{code}-#{build}" if code && build
    rescue JSON::ParserError
      nil
    end
  end

  # This method is used to detect the build of the IDE on macOS from build.txt
  #
  # @example
  #   RM-252.23892.415
  # @return [String] build info.
  # @return [nil] if build.txt not found or empty.
  def info_from_build_txt
    build_txt = File.join(app_bundle_path, 'Contents', 'Resources', 'build.txt')
    return unless File.file?(build_txt)

    bn = File.read(build_txt, encoding: 'UTF-8').strip
    code = PRODUCT_CODE_GUESS[display_name_for_base]
    "#{code}-#{bn}" unless bn.empty?
  end

  # This method is used to get the path to the .app bundle for the IDE on macOS.
  #
  # @return [String] path to the .app bundle for the IDE.
  # @see JBUpdater#ide_name_from_plugins_dir
  # @see JBUpdater#display_name_for_base
  def app_bundle_path
    @app_bundle_path ||= begin
      app_name = BASE_TO_APP[ide_name_from_plugins_dir] || "#{display_name_for_base}.app"
      candidate = File.join('/Applications', app_name)
      candidate if File.directory?(candidate)
    end
  end

  # This method returns displayed app name for the current IDE. This is used to get the code of IDE in next steps
  #
  # @example
  #   'IntelliJIdea' -> 'IntelliJ IDEA Ultimate'
  # @return [String] displayed app name
  def display_name_for_base
    @display_name_for_base ||= BASE_TO_DISPLAY[ide_name_from_plugins_dir] || ide_name_from_plugins_dir
  end

  # This method infers the name of the IDE from the plugins directory.
  #
  # @example
  #   ".../JetBrains/RubyMine2025.2/plugins" -> "RubyMine"
  # @return [String] name of the IDE
  def ide_name_from_plugins_dir
    @ide_name_from_plugins_dir ||= File.basename(File.dirname(opts[:plugins_dir].to_s)).sub(/\d.*\z/, '')
  end

  # This method lists all installed plugins for the current build
  # @see JBUpdater#installed_plugins
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
          puts "  installed: #{post_id} #{post_ver} [since=#{post_since || '-'} until=#{post_until || '-'}] #{
            '(still incompatible!)' unless compat}"
        ensure
          FileUtils.rm_f(tmp_zip)
        end
      rescue StandardError => e
        warn "[#{xml_id}] failed: #{e}"
      end
    end

    puts 'Done. Start the IDE to load updated plugins.'
  end

  # ---------- plugin scanning ----------
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

  def parse_plugin_meta_from_dir(plugin_dir)
    # unpacked META-INF/plugin.xml
    xml_path = File.join(plugin_dir, 'META-INF', 'plugin.xml')
    if File.file?(xml_path)
      xml = File.read(xml_path, encoding: 'UTF-8')
      return parse_plugin_xml(xml)
    end
    # inside jars
    Dir.glob(File.join(plugin_dir, 'lib', '*.jar')).each do |jar|
      xml = read_text_from_jar(jar, 'META-INF/plugin.xml')
      next unless xml && !xml.empty?

      return parse_plugin_xml(xml)
    end
    [nil, nil, nil, nil]
  end

  def parse_plugin_xml(xml)
    doc = REXML::Document.new(xml)
    id = REXML::XPath.first(doc, '//id')&.text&.strip
    version = REXML::XPath.first(doc, '//version')&.text&.strip
    id ||= REXML::XPath.first(doc, '//name')&.text&.strip
    iv = REXML::XPath.first(doc, '//idea-version')
    since = iv&.attributes&.[]('since-build') || iv&.attributes&.[]('sinceBuild')
    untl = iv&.attributes&.[]('until-build') || iv&.attributes&.[]('untilBuild')
    [id, version, since, untl]
  rescue REXML::ParseException
    [nil, nil, nil, nil]
  end

  # ---------- build compare ----------

  def build_in_range?(build_str, since_str, until_str)
    b = parse_build_string(build_str)
    s = since_str && !since_str.empty? ? parse_build_string(since_str) : [0, 0, 0]
    u = until_str && !until_str.empty? ? parse_build_string(until_str) : [INF, INF, INF]
    ((s <=> b) <= 0) && ((b <=> u) <= 0)
  end

  def parse_build_string(str)
    return nil if str.nil? || str.empty?

    core = str.sub(/\A[A-Z]+-/, '')
    parts = core.split('.', 3)
    parts.map! { |p| p == '*' ? INF : p.to_i }
    parts.fill(0, parts.length...3)
  end

  # ---------- HTTP / downloads ----------

  def http_head_or_get(url, method: :get)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      req = method == :head ? Net::HTTP::Head.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
      req['User-Agent'] = 'jb-updater/mac/1.0 (+ruby)'
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
      req['User-Agent'] = 'jb-updater/mac/1.0 (+ruby)'
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
    raise "'unzip' not found in PATH" unless unzip_available?

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

  # ---------- misc utils ----------

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

  def safe(s) = s.to_s.gsub(/[^\w.-]/, '_')

  def read_text_from_jar(jar_path, inner_path)
    out, st = run_cmd('unzip', '-p', jar_path, inner_path)
    st.success? ? out : nil
  rescue Errno::ENOENT
    nil
  end

  def run_cmd(cmd, *) = Open3.capture2e(cmd, *)

  def which(cmd)
    out, st = Open3.capture2e('which', cmd)
    st.success? ? out.strip : nil
  end
end

# ----------------------------
# CLI wrapper (macOS-only)
# ----------------------------
if __FILE__ == $PROGRAM_NAME
  # binding.irb
  # TracePoint.trace(:return) do |tp|
  #   unless tp.return_value.instance_of?(OptionParser) || tp.return_value.instance_of?(REXML::Element) || %i[filter_targets
  #                                                                                                           installed_plugins read_text_from_jar run_cmd rewrite_to_downloads_host resolve_download_url_via_plugin_manager].include?(tp.method_id) || !JBUpdater.instance_methods(false).include?(tp.method_id)
  #     puts "method `#{tp.method_id}' returned #{tp.return_value.inspect} on line ##{tp.lineno}"
  #   end
  # end
  cli_opts = { pin_versions: {}, direct_urls: {} }
  OptionParser.new do |o|
    o.banner = 'Usage: ruby jb_updater_mac.rb --plugins-dir DIR [--build BUILD] [options]'
    o.on('--plugins-dir DIR', 'Path to ~/Library/Application Support/JetBrains/<ProductYYYY.X>/plugins') do |v|
      cli_opts[:plugins_dir] = v
    end
    o.on('--build BUILD', 'IDE build, e.g. RM-252.23892.415 (auto-detect if omitted)') { |v| cli_opts[:build] = v }
    o.on('--bin-path PATH', 'Explicit path to IDE binary (override detection)') { |v| cli_opts[:bin_path] = v }
    o.on('--only IDS', Array, 'CSV of xmlIds to update (default: all installed)') { |v| cli_opts[:only] = v }
    o.on('--only-incompatible', 'Limit to plugins incompatible with current build') do
      cli_opts[:only_incompatible] = true
    end
    o.on('--downloads-host HOST', 'Rewrite /files/ host (e.g. downloads.marketplace.jetbrains.com)') do |v|
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

  updater = JBUpdater.new(cli_opts)
  updater.run
end
