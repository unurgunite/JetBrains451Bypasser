require "./jb_updater"

opts = JBUpdater.parse_cli
updater = JBUpdater::Updater.new(opts)
updater.run
