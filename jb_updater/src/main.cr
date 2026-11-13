require "./jb_updater"

begin
  opts = JBUpdater.parse_cli

  JBUpdater::HTTPClient.no_tty_progress_bar = opts.no_tty_progress_bar?

  if opts.product && opts.ide_path
    JBUpdater::Log.fatal(
      "Specify either --product or --ide-path, not both.",
      "Drop one of the flags (see --help)."
    )
  end

  # ---------------------------------------------------------------------
  # Decide what the user wants to do
  # ---------------------------------------------------------------------

  # Case 0: just list IDE releases (Toolbox-like discovery)
  if opts.list_ide_releases?
    if opts.product.nil?
      JBUpdater::Log.fatal(
        "Missing --product when using --list-ide-releases.",
        "Example: jb_updater --product RM --list-ide-releases"
      )
    end

    product_code = opts.product || raise "missing --product"
    product_code = JBUpdater::Utils.product_code(product_code)

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
  if opts.upgrade_ide?
    ide_updater = JBUpdater::IDEUpdater.new(opts)
    ide_updater.run
    exit 0
  end

  # ---------------------------------------------------------------------
  # Resolve plugins directory automatically if only --product is passed
  # (for plugin operations only, not IDE modes above)
  # ---------------------------------------------------------------------
  if opts.plugins_dir.nil? && (product = opts.product)
    resolved = JBUpdater::Utils.resolve_product_folder(product)
    opts.plugins_dir = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
    puts "Detected latest config folder: #{resolved}"
  end

  # Case 2: normal plugin update / install / list
  if pd = opts.plugins_dir
    # Expand ~ in plugins_dir, if present
    opts.plugins_dir = JBUpdater::Utils.expand_tilde(pd)

    plugins_dir = opts.plugins_dir || pd
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
rescue ex
  msg, hint = JBUpdater::Log.explain(ex)
  JBUpdater::Log.fatal(msg, hint)
end
