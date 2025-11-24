require "./jb_updater"

opts = JBUpdater.parse_cli

if opts.product && opts.ide_path
  JBUpdater::Log.fail("Specify either --product or --ide-path, not both.")
  exit 1
end

# ---------------------------------------------------------------------
# Decide what the user wants to do
# ---------------------------------------------------------------------

# Case 0: just list IDE releases (Toolbox-like discovery)
# Case 0: just list IDE releases (Toolbox-like discovery)
if opts.list_ide_releases
  if opts.product.nil?
    JBUpdater::Log.fail("Missing --product when using --list-ide-releases (e.g., WS, RM)")
    exit 1
  end

  product_code = opts.product.not_nil!
  releases = JBUpdater::IDEReleases.fetch(
    product_code,
    channel: "release",
    downloads_host: opts.ide_downloads_host,
    arch: opts.arch,
    latest: false
  )
  puts "Available releases for #{product_code}:"
  releases.each do |rel|
    puts "- #{rel.version} (#{rel.channel}) #{rel.date}  -> #{rel.link}"
  end
  exit 0
end

# Case 1: explicit IDE upgrade mode
if opts.upgrade_ide
  ide_updater = JBUpdater::IDEUpdater.new(opts)
  ide_updater.run
  exit 0
end

# ---------------------------------------------------------------------
# Resolve plugins directory automatically if only --product is passed
# (for plugin operations only, not IDE modes above)
# ---------------------------------------------------------------------
if opts.plugins_dir.nil? && opts.product
  resolved = JBUpdater::Utils.resolve_product_folder(opts.product.not_nil!)
  opts.plugins_dir = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
  puts "Detected latest config folder: #{resolved}"
end

# Case 2: normal plugin update / install / list
if opts.plugins_dir
  plugins_dir = opts.plugins_dir.not_nil!
  puts "Scanning #{plugins_dir}"

  if Dir.exists?(plugins_dir)
    Dir.each_child(plugins_dir) { |e| puts "→ #{e}" }
  else
    JBUpdater::Log.warn "Plugins dir '#{plugins_dir}' not found"
  end

  updater = JBUpdater::Updater.new(opts)
  updater.run
  exit 0
end

# If neither condition matched, print a brief help hint
puts "Usage: jb_updater --plugins-dir <path> [options] or --product <IDE>"
exit 1
