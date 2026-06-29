require "json"
require "./utils"

module JBUpdater
  struct DetectedProduct
    getter name : String         # e.g. "RubyMine2025.2"
    getter code : String         # e.g. "RM"
    getter build : String        # e.g. "RM-252" (for API calls)
    getter ide_path : String?    # e.g. "/Applications/RubyMine2025.2.app" or install dir
    getter config_dir : String?  # e.g. "~/Library/.../RubyMine2025.2"
    getter plugins_dir : String? # e.g. ".../plugins"

    def initialize(@name : String, @code : String, @build : String, @ide_path : String?, @config_dir : String?, @plugins_dir : String?)
    end
  end

  module DetectProducts
    extend self

    # Map patterns in config/IDE names to canonical base names
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

    def all : Array(DetectedProduct)
      products = [] of DetectedProduct

      {% if flag?(:darwin) %}
        # macOS: detect from /Applications and map to JetBrains config base
        apps = Dir.glob("/Applications/*.app")
        apps.each do |app|
          base = File.basename(app)     # "RubyMine2025.2.app"
          name = base.sub(/\.app$/, "") # "RubyMine2025.2"

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
        # Linux: detect from JetBrains config base (~/.local/share/JetBrains)
        config_base = Utils.jetbrains_config_base
        if Dir.exists?(config_base)
          Dir.each_child(config_base) do |entry|
            full = File.join(config_base, entry)
            next unless Dir.exists?(full)

            pair = KNOWN_NAMES.find { |rx, _| rx =~ entry }
            next unless pair
            matched_name = pair[1]

            name = entry # full config folder name, e.g. "WebStorm2025.2"
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
            matched_name = pair[1]

            name = entry
            code = infer_code(name)
            build = build_code(name, code)
            plugins_dir = File.join(full, "plugins")

            products << DetectedProduct.new(
              name: name,
              code: code,
              build: build,
              ide_path: nil, # install path varies
              config_dir: full,
              plugins_dir: Dir.exists?(plugins_dir) ? plugins_dir : nil
            )
          end
        end
      {% end %}

      products.sort_by!(&.name.downcase)
      products
    end

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

      key = name.gsub(/[\d ].*/, "") # strip year/build and trailing words
      mapping[key]? || name[0, 2].upcase
    end

    # Convert "RubyMine2025.2" and code "RM" → "RM-252"
    # If name has no version number, fallback to reading from app bundle
    def build_code(name : String, code : String, ide_path : String? = nil) : String
      ver = name.gsub(/[^0-9.]/, "") # "2025.2"
      parts = ver.split(".").first(2)  # ["2025", "2"]
      if parts.size == 2 && !ver.empty?
        year = parts[0]                # "2025"
        major = parts[1]               # "2"
        major = major.split("-").first # strip any suffix
        num_build = year[2..] + major  # "252"
        "#{code}-#{num_build}"
      elsif ide_path
        read_build_from_app(ide_path, code) || "#{code}-#{ver}"
      else
        "#{code}-#{ver}"
      end
    end

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

    def app_metadata_path(ide_path : String, file : String) : String
      {% if flag?(:darwin) %}
        File.join(ide_path, "Contents", "Resources", file)
      {% else %}
        File.join(File.dirname(ide_path), file)
      {% end %}
    end
  end
end
