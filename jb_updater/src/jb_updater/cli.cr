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
    property ide_path : String?
    property brew_patch : Bool?
    property upgrade_ide : Bool
    property ide_downloads_host : String
    property arch : String?

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
      @brew_patch = false
      @upgrade_ide = false
      @ide_downloads_host = "download-cdn.jetbrains.com"
      @arch = nil
      @ide_path = nil
    end
  end

  def self.parse_cli : Options
    opts = Options.new

    OptionParser.parse do |parser|
      parser.banner = "Usage: jb_updater [options]"
      parser.on("--plugins-dir DIR", "Plugins directory") { |v| opts.plugins_dir = v }
      parser.on("-b", "--build BUILD", "IDE build") { |v| opts.build = v }
      parser.on("-d", "--dry-run", "Dry run") { opts.dry_run = true }
      parser.on("-l", "--list", "List plugins") { opts.list = true }
      parser.on("-i", "--install-plugin IDS", "Install plugins (comma-separated)") { |v| opts.install_ids = v.split(',') }
      parser.on("--product NAME", "IDE product name (e.g., RubyMine or RubyMine2025.2)") do |v|
        opts.product = v
      end
      parser.on("--arch ARCH", "Architecture (arm or intel); default: autodetect") do |v|
        opts.arch = v.downcase
      end
      parser.on("--upgrade-ide", "Upgrade whole IDE instead of plugins") { opts.upgrade_ide = true }
      parser.on("--ide-path PATH", "Specify custom IDE installation path") do |v|
        opts.ide_path = v
      end
      parser.on("--brew", "Patch Homebrew cask Ruby file instead of direct install") { opts.brew_patch = nil }
      parser.on("-h", "--help", "Show help") do
        puts parser
        exit 0
      end
    end

    opts
  end
end
