require "./jb_updater"

opts = JBUpdater.parse_cli

if opts.plugins_dir.nil?
  if product = opts.product
    resolved = JBUpdater::Utils.resolve_product_folder(product)
    opts.plugins_dir = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
    puts "Detected latest config folder: #{resolved}"
  else
    puts "Need either --plugins-dir or --product <Name>"
    exit 1
  end
end

plugins_dir = opts.plugins_dir.not_nil!

puts "Scanning #{plugins_dir}"
if Dir.exists?(plugins_dir)
  Dir.each_child(plugins_dir) { |entry| puts "→ #{entry}" }
else
  JBUpdater::Log.warn "Plugins dir '#{plugins_dir}' not found"
end

updater = JBUpdater::Updater.new(opts)
updater.run
