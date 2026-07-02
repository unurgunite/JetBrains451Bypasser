require "option_parser"

module JBUpdater
  # CLI options parsed from command-line arguments.
  #
  # All fields default to `nil`/`false`/empty values and are set
  # by {JBUpdater.parse_cli} based on `OptionParser` flags.
  class Options
    # Custom plugins directory override.
    property plugins_dir : String?
    # IDE build string (e.g. `"RM-252"`).
    property build : String?
    # Plugin IDs to restrict operations to.
    property only : Array(String)
    # Whether to include incompatible plugins.
    property? only_incompatible : Bool
    # When true, skip actual operations.
    property? dry_run : Bool
    # Override for the plugin downloads host.
    property downloads_host : String
    # Map of plugin IDs to pinned versions.
    property pin_versions : Hash(String, String)
    # Map of plugin IDs to direct download URLs.
    property direct_urls : Hash(String, String)
    # When true, list plugins instead of updating.
    property? list : Bool
    # Custom path to IDE binary (macOS only).
    property bin_path : String?
    # Whether to include bundled plugins.
    property? include_bundled : Bool
    # Plugin XML IDs to install (comma-separated on CLI).
    property install_ids : Array(String)
    # IDE product name (e.g. `"RubyMine"` or `"RubyMine2025.2"`).
    property product : String?
    # Custom IDE installation path.
    property ide_path : String?
    # When true, patch a Homebrew cask file instead of installing directly.
    property brew_patch : Bool?
    # When true, upgrade the whole IDE rather than individual plugins.
    property? upgrade_ide : Bool
    # Override for the IDE downloads host (default: download-cdn.jetbrains.com).
    property ide_downloads_host : String
    # Target architecture (`"arm"` or `"intel"`); autodetected if nil.
    property arch : String?
    # When true, list available IDE releases for `--product`.
    property? list_ide_releases : Bool
    # When true, disable ASCII download progress bars.
    property? no_tty_progress_bar : Bool

    # All fields default to `nil`, `false`, or empty collections.
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
      @list_ide_releases = false
      @no_tty_progress_bar = false
    end
  end

  # Parses ARGV and returns an {Options} struct.
  #
  # Supported flags:
  #
  # - `--plugins-dir DIR`
  # - `-b` / `--build BUILD`
  # - `-d` / `--dry-run`
  # - `-l` / `--list`
  # - `-i` / `--install-plugin IDS`
  # - `--product NAME`
  # - `--arch ARCH`
  # - `--upgrade-ide`
  # - `--ide-path PATH`
  # - `--list-ide-releases`
  # - `--ide-downloads-host HOST`
  # - `--no-tty-progress-bar`
  # - `--brew`
  # - `-h` / `--help`
  #
  # @return [Options] Parsed CLI options
  def self.parse_cli(argv = ARGV) : Options
    opts = Options.new

    OptionParser.parse(argv) do |parser|
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
      parser.on("--list-ide-releases", "List IDE releases for given --product code") do
        opts.list_ide_releases = true
      end
      parser.on("--ide-downloads-host HOST", "Override IDE downloads host (default: download-cdn.jetbrains.com)") do |v|
        opts.ide_downloads_host = v
      end
      parser.on("--no-tty-progress-bar", "Disable ASCII progress bars on stdout for downloads") do
        opts.no_tty_progress_bar = true
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
