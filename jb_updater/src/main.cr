require "./jb_updater"

opts = JBUpdater.parse_cli

# ---------------------------------------------------------------------
# Resolve plugins directory automatically if only --product is passed
# ---------------------------------------------------------------------
if opts.plugins_dir.nil? && opts.product
  resolved = JBUpdater::Utils.resolve_product_folder(opts.product.not_nil!)
  opts.plugins_dir = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
  puts "Detected latest config folder: #{resolved}"
end

# ---------------------------------------------------------------------
# Decide what the user wants to do
# ---------------------------------------------------------------------
# Case 1: explicit IDE upgrade mode
if opts.upgrade_ide
  ide_updater = JBUpdater::IDEUpdater.new(opts)
  ide_updater.run
  exit 0
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
puts "Usage: jb_updater --plugins-dir <path> [options] or --product <IDE> [--brew]"
exit 1
