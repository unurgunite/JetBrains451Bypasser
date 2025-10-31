require "option_parser"

module JBUpdater
  class Options
    property plugins_dir : String?
    property build : String?
    property only : Array(String)
    property only_incompatible : Bool
    property dry_run : Bool
    property downloads_host : String
    property pin_versions : Hash(String, String)
    property direct_urls : Hash(String, String)
    property list : Bool
    property bin_path : String?
    property include_bundled : Bool
    property install_ids : Array(String)
    property product : String?

    def initialize
      @only = [] of String
      @only_incompatible = false
      @dry_run = false
      @downloads_host = "downloads.marketplace.jetbrains.com"
      @pin_versions = {} of String => String
      @direct_urls = {} of String => String
      @list = false
      @include_bundled = false
      @install_ids = [] of String
      @product = nil
    end
  end

  def self.parse_cli : Options
    opts = Options.new

    OptionParser.parse do |parser|
      parser.banner = "Usage: jb_updater [options]"
      parser.on("--plugins-dir DIR", "Plugins directory") { |v| opts.plugins_dir = v }
      parser.on("--build BUILD", "IDE build") { |v| opts.build = v }
      parser.on("--dry-run", "Dry run") { opts.dry_run = true }
      parser.on("--list", "List plugins") { opts.list = true }
      parser.on("--install-plugin IDS", "Install plugins (comma-separated)") { |v| opts.install_ids = v.split(',') }
      parser.on("--product NAME", "IDE product name (e.g., RubyMine or RubyMine2025.2)") do |v|
        opts.product = v
      end
      parser.on("-h", "--help", "Show help") do
        puts parser
        exit 0
      end
    end

    opts
  end
end
