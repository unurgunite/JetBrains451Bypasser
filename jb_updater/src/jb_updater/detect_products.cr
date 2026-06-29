require "json"
require "./utils"

module JBUpdater
  # A locally detected JetBrains IDE installation.
  #
  # Populated by {DetectProducts.all} with the name, product code,
  # build string, and optional paths for the IDE binary, config
  # directory, and plugins directory.
  struct DetectedProduct
    # e.g. "RubyMine2025.2"
    getter name : String
    # Product code (e.g. "RM", "WS", "PY").
    getter code : String
    # Build string for API calls (e.g. "RM-252").
    getter build : String
    # Path to the IDE install directory or `.app` bundle, or `nil`.
    getter ide_path : String?
    # Path to the IDE config directory (e.g. `~/Library/.../RubyMine2025.2`), or `nil`.
    getter config_dir : String?
    # Path to the plugins directory, or `nil`.
    getter plugins_dir : String?

    # @param name [String] Display name (e.g. "RubyMine2025.2")
    # @param code [String] Product code (e.g. "RM")
    # @param build [String] Build string (e.g. "RM-252")
    # @param ide_path [String?] IDE install path
    # @param config_dir [String?] Config directory path
    # @param plugins_dir [String?] Plugins directory path
    def initialize(@name : String, @code : String, @build : String, @ide_path : String?, @config_dir : String?, @plugins_dir : String?)
    end
  end

  # Scans the local system for installed JetBrains products.
  #
  # Detection strategy varies by platform:
  # - **macOS**: globs `/Applications/*.app` and matches known product names.
  # - **Linux / Windows**: iterates JetBrains config base directory entries
  #   and matches against {KNOWN_NAMES}.
  module DetectProducts
    extend self

    # Maps product name patterns to canonical display names.
    KNOWN_NAMES = {
      /RubyMine/i => "RubyMine",
      /WebStorm/i => "WebStorm",
      /PyCharm/i  => "PyCharm",
      /CLion/i    => "CLion",
      /GoLand/i   => "GoLand",
      /IntelliJ/i => "IntelliJ",
      /PhpStorm/i => "PhpStorm",
      /Rider/i    => "Rider",
    }

    # Scans the system for all installed JetBrains products.
    #
    # On macOS, detection is based on `.app` bundles in `/Applications`.
    # On Linux and Windows, the config base directory is scanned instead.
    #
    # Results are sorted alphabetically by name (case-insensitive).
    #
    # @return [Array(DetectedProduct)] All detected products
    def all : Array(DetectedProduct)
      products = [] of DetectedProduct

      {% if flag?(:darwin) %}
        apps = Dir.glob("/Applications/*.app")
        apps.each do |app|
          base = File.basename(app)
          name = base.sub(/\.app$/, "")

          next unless name =~ /RubyMine|WebStorm|PyCharm|CLion|GoLand|IntelliJ|PhpStorm|Rider/i

          code = infer_code(name)
          build = build_code(name, code, app)

          config_base = Utils.jetbrains_config_base
          config_dir = Dir.glob(File.join(config_base, "#{name}*")).first?
          plugins_dir = config_dir ? File.join(config_dir, "plugins") : nil

          products << DetectedProduct.new(
            name: name,
            code: code,
            build: build,
            ide_path: app,
            config_dir: config_dir,
            plugins_dir: plugins_dir
          )
        end
      {% elsif flag?(:linux) %}
        config_base = Utils.jetbrains_config_base
        if Dir.exists?(config_base)
          Dir.each_child(config_base) do |entry|
            full = File.join(config_base, entry)
            next unless Dir.exists?(full)

            pair = KNOWN_NAMES.find { |rx, _| rx =~ entry }
            next unless pair
            matched_name = pair[1]

            name = entry
            code = infer_code(name)
            build = build_code(name, code)
            plugins_dir = File.join(full, "plugins")

            products << DetectedProduct.new(
              name: name,
              code: code,
              build: build,
              ide_path: nil,
              config_dir: full,
              plugins_dir: Dir.exists?(plugins_dir) ? plugins_dir : nil
            )
          end
        end
      {% elsif flag?(:win32) %}
        config_base = Utils.jetbrains_config_base
        if Dir.exists?(config_base)
          Dir.each_child(config_base) do |entry|
            full = File.join(config_base, entry)
            next unless Dir.exists?(full)

            pair = KNOWN_NAMES.find { |rx, _| rx =~ entry }
            next unless pair

            name = entry
            code = infer_code(name)
            build = build_code(name, code)
            plugins_dir = File.join(full, "plugins")

            products << DetectedProduct.new(
              name: name,
              code: code,
              build: build,
              ide_path: nil,
              config_dir: full,
              plugins_dir: Dir.exists?(plugins_dir) ? plugins_dir : nil
            )
          end
        end
      {% end %}

      products.sort_by!(&.name.downcase)
      products
    end

    # Infers the product code from a product name.
    #
    # Strips trailing version numbers and looks up the short code
    # (e.g. "RubyMine" → "RM"). Falls back to the first two
    # uppercase characters of the name.
    #
    # @param name [String] Product name (e.g. "RubyMine2025.2")
    # @return [String] Product code (e.g. "RM")
    def infer_code(name : String) : String
      mapping = {
        "RubyMine" => "RM",
        "WebStorm" => "WS",
        "PyCharm"  => "PY",
        "CLion"    => "CL",
        "GoLand"   => "GO",
        "IntelliJ" => "IU",
        "PhpStorm" => "PS",
        "Rider"    => "RD",
      }

      key = name.gsub(/[\d ].*/, "")
      mapping[key]? || name[0, 2].upcase
    end

    # Converts a product name and code into an API build string.
    #
    # Example: `"RubyMine2025.2"`, `"RM"` → `"RM-252"`
    #
    # Falls back to reading `product-info.json` or `build.txt`
    # from the app bundle if no version is embedded in the name.
    #
    # @param name [String] Product name
    # @param code [String] Product code
    # @param ide_path [String?] Path to IDE (needed for app bundle fallback)
    # @return [String] Build string (e.g. `"RM-252"`)
    def build_code(name : String, code : String, ide_path : String? = nil) : String
      ver = name.gsub(/[^0-9.]/, "")
      parts = ver.split(".").first(2)
      if parts.size == 2 && !ver.empty?
        year = parts[0]
        major = parts[1]
        major = major.split("-").first
        num_build = year[2..] + major
        "#{code}-#{num_build}"
      elsif ide_path
        read_build_from_app(ide_path, code) || "#{code}-#{ver}"
      else
        "#{code}-#{ver}"
      end
    end

    # Reads the build number from an application bundle's metadata files.
    #
    # Checks `product-info.json` ("buildNumber" field) first, then
    # falls back to `build.txt`.
    #
    # @param ide_path [String] Path to the IDE `.app` bundle
    # @param code [String] Product code used to prefix the result
    # @return [String?] Full build string (e.g. `"RM-261.25134.97"`) or `nil`
    def read_build_from_app(ide_path : String, code : String) : String?
      info_json = app_metadata_path(ide_path, "product-info.json")
      build_txt = app_metadata_path(ide_path, "build.txt")

      if File.file?(info_json)
        begin
          data = JSON.parse(File.read(info_json))
          if build = data["buildNumber"]?.try(&.as_s)
            Log.info "Read build #{build} from #{info_json}"
            return "#{code}-#{build}"
          end
        rescue
        end
      end

      if File.file?(build_txt)
        build = File.read(build_txt).strip
        unless build.empty?
          Log.info "Read build #{build} from #{build_txt}"
          return "#{code}-#{build}"
        end
      end

      nil
    end

    # Resolves the path to a metadata file inside an IDE installation.
    #
    # On macOS the resources are under `Contents/Resources/` inside the
    # `.app` bundle; on other platforms they sit next to the IDE binary.
    #
    # @param ide_path [String] Path to the IDE install
    # @param file [String] Metadata filename (e.g. `"product-info.json"`)
    # @return [String] Full filesystem path
    def app_metadata_path(ide_path : String, file : String) : String
      {% if flag?(:darwin) %}
        File.join(ide_path, "Contents", "Resources", file)
      {% else %}
        File.join(File.dirname(ide_path), file)
      {% end %}
    end
  end
end
