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

def log(msg)
  puts(msg)
end

def warnln(msg)
  warn(msg)
end

def run(cmd, *args)
  Open3.capture2e(cmd, *args)
end

def unzip_available?
  system('which', 'unzip', out: File::NULL, err: File::NULL)
end

def read_text_from_jar(jar_path, inner_path)
  out, st = run('unzip', '-p', jar_path, inner_path)
  st.success? ? out : nil
rescue Errno::ENOENT
  warnln 'unzip not found; install unzip or adjust script'
  nil
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

def parse_plugin_meta_from_dir(plugin_dir)
  # case 1: unpacked META-INF/plugin.xml
  xml_path = File.join(plugin_dir, 'META-INF', 'plugin.xml')
  if File.file?(xml_path)
    xml = File.read(xml_path, encoding: 'UTF-8')
    id, ver, since, untl = parse_plugin_xml(xml)
    return [id, ver, since, untl] if id
  end
  # case 2: inside jar(s) under lib
  Dir.glob(File.join(plugin_dir, 'lib', '*.jar')).each do |jar|
    xml = read_text_from_jar(jar, 'META-INF/plugin.xml')
    next unless xml && !xml.empty?

    id, ver, since, untl = parse_plugin_xml(xml)
    return [id, ver, since, untl] if id
  end
  [nil, nil, nil, nil]
end

def list_installed_plugins(plugins_dir)
  result = {}
  Dir.children(plugins_dir).sort.each do |entry|
    next if entry.start_with?('.')

    path = File.join(plugins_dir, entry)
    next unless File.directory?(path)

    id, ver, since, untl = parse_plugin_meta_from_dir(path)
    next unless id

    result[id] = { 'version' => ver, 'path' => path, 'folder' => entry, 'since' => since, 'until' => untl }
  end
  result
end

# -------- build compare helpers --------
INF = 1.0 / 0.0

def parse_build_string(str)
  return nil if str.nil? || str.empty?

  core = str.sub(/\A[A-Z]+-/, '') # strip "RM-" etc
  parts = core.split('.', 3)
  parts.map! do |p|
    if p == '*'
      INF
    else
      p.to_i
    end
  end
  parts.fill(0, parts.length...3) # pad to 3 numbers
end

def build_in_range?(build_str, since_str, until_str)
  b = parse_build_string(build_str)
  s = since_str && !since_str.empty? ? parse_build_string(since_str) : [0, 0, 0]
  u = until_str && !until_str.empty? ? parse_build_string(until_str) : [INF, INF, INF]
  ((s <=> b) <= 0) && ((b <=> u) <= 0)
end

def detect_build_from_rubymine
  binding.irb
  candidates = [
    '/Applications/RubyMine.app/Contents/MacOS/rubymine',
    ENV['RUBYMINE_BIN']
  ].compact
  bin = candidates.find { |p| p && File.executable?(p) }
  return nil unless bin

  out, _st = run(bin, '--version')
  # "Build #RM-252.23892.415"
  if out =~ /Build\s+#([A-Z]{2})-(\d+\.\d+\.\d+)/
    product = Regexp.last_match(1)
    build = Regexp.last_match(2)
    "#{product}-#{build}"
  elsif out =~ /Build\s+#([A-Z]{2}-\S+)/
    Regexp.last_match(1)
  end
end

# --------------------------------------

def http_head_or_get(url, method: :get, limit: 5)
  raise 'too many redirects' if limit <= 0

  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    req = method == :head ? Net::HTTP::Head.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
    req['User-Agent'] = 'jb-auto-update/1.1 (+ruby)'
    http.request(req)
  end
end

def resolve_download_url_via_plugin_manager(xml_id, build)
  base = "https://plugins.jetbrains.com/pluginManager?action=download&id=#{CGI.escape(xml_id)}&build=#{CGI.escape(build)}"
  res = http_head_or_get(base, method: :get)
  case res
  when Net::HTTPRedirection
    loc = res['location'] or raise 'Missing Location header from pluginManager'
    loc_uri = URI.parse(loc)
    loc_uri = URI.join('https://plugins.jetbrains.com', loc) unless loc_uri.absolute?
    loc_uri
  when Net::HTTPSuccess
    URI(base)
  else
    code = res.code.to_i
    raise "pluginManager failed (HTTP #{code}) for #{xml_id} build #{build}"
  end
end

def resolve_download_url_for_version(xml_id, version)
  base = "https://plugins.jetbrains.com/plugin/download?pluginId=#{CGI.escape(xml_id)}&version=#{CGI.escape(version)}"
  res = http_head_or_get(base, method: :get)
  case res
  when Net::HTTPRedirection
    loc = res['location'] or raise 'Missing Location header'
    loc_uri = URI.parse(loc)
    loc_uri = URI.join('https://plugins.jetbrains.com', loc) unless loc_uri.absolute?
    loc_uri
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
    req['User-Agent'] = 'jb-auto-update/1.1 (+ruby)'
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
  raise 'unzip not available' unless unzip_available?

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
      log "Backed up: #{dest_dir} -> #{backup}"
    end
    FileUtils.mkdir_p(File.dirname(dest_dir))
    FileUtils.mv(root, dest_dir)
  end
  true
end

def main
  opts = {
    plugins_dir: nil,
    build: nil,
    only: [],
    only_incompatible: false,
    dry_run: false,
    downloads_host: nil, # e.g. "downloads.marketplace.jetbrains.com"
    pin_versions: {}, # xmlId => version
    direct_urls: {}, # xmlId => https://.../files/...zip
    list: false
  }

  OptionParser.new do |o|
    o.banner = 'Usage: ruby jb_auto_update.rb --plugins-dir DIR [--build BUILD] [options]'
    o.on('--plugins-dir DIR', 'Path to .../RubyMine2025.2/plugins') { |v| opts[:plugins_dir] = v }
    o.on('--build BUILD', 'IDE build, e.g. RM-252.23892.415 (auto-detect if omitted)') { |v| opts[:build] = v }
    o.on('--only IDS', Array, 'CSV of xmlIds to update (default: all installed)') { |v| opts[:only] = v }
    o.on('--only-incompatible',
         'Limit updates to plugins incompatible with the current build (uses plugin.xml idea-version)') do
      opts[:only_incompatible] = true
    end
    o.on('--downloads-host HOST', 'Rewrite /files/ host to this (e.g. downloads.marketplace.jetbrains.com)') do |v|
      opts[:downloads_host] = v
    end
    o.on('--pin PAIR', 'Pin xmlId=version (can repeat)') do |v|
      id, ver = v.split('=', 2)
      opts[:pin_versions][id] = ver if id && ver
    end
    o.on('--direct PAIR', 'Use direct URL for xmlId: xmlId=https://... (can repeat)') do |v|
      id, url = v.split('=', 2)
      opts[:direct_urls][id] = url if id && url
    end
    o.on('--dry-run', 'Show actions without downloading/installing') { opts[:dry_run] = true }
    o.on('--list', 'List installed plugins with compatibility status and exit') { opts[:list] = true }
    o.on('-h', '--help', 'Show help') do
      puts o
      exit 0
    end
  end.parse!

  unless opts[:plugins_dir] && Dir.exist?(opts[:plugins_dir])
    warnln "Plugins dir not found: #{opts[:plugins_dir]}"
    exit 2
  end

  build = opts[:build] || detect_build_from_rubymine
  unless build
    warnln 'Could not detect build; pass --build RM-252.23892.415'
    exit 2
  end

  installed = list_installed_plugins(opts[:plugins_dir])

  if opts[:list]
    if installed.empty?
      puts "No plugins found in #{opts[:plugins_dir]}"
      exit 0
    end
    id_w = installed.keys.map(&:length).max
    ver_w = installed.values.map { |m| (m['version'] || '').length }.max
    puts "Installed plugins for build #{build}:"
    installed.each do |pid, meta|
      ver = meta['version'] || 'unknown'
      since = meta['since'] || ''
      untl = meta['until'] || ''
      status = build_in_range?(build, since, untl) ? 'OK' : 'incompatible'
      printf("- %-#{id_w}s  %-#{ver_w}s  [since=%-8s until=%-8s]  %s\n", pid, ver, since || '-', untl || '-', status)
    end
    exit 0
  end

  # Filter
  installed.select! { |k, _| opts[:only].include?(k) } unless opts[:only].empty?
  if opts[:only_incompatible]
    installed.reject! do |_, meta|
      build_in_range?(build, meta['since'], meta['until'])
    end
  end

  if installed.empty?
    puts "No matching plugins to update in #{opts[:plugins_dir]}"
    exit 0
  end

  puts "Build: #{build}"
  puts "Checking #{installed.size} plugin(s)"

  installed.each do |xml_id, meta|
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

      tmp_zip = File.join(Dir.tmpdir, "jb-#{xml_id.gsub(/[^\w.-]/, '_')}-#{Time.now.to_i}.zip")
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
      warnln "[#{xml_id}] failed: #{e}"
    end
  end

  puts 'Done. Start RubyMine to load updated plugins.'
end

main
