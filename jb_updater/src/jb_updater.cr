require "./jb_updater/cli"
require "./jb_updater/updater"

# TODO: Write documentation for `JbUpdater`
module JbUpdater
  VERSION = "0.1.0"

  # TODO: Put your code here
end

opts = JBUpdater.parse_cli
updater = JBUpdater::Updater.new(opts)
updater.run
