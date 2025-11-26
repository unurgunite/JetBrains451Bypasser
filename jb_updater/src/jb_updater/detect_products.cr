require "json"
require "./utils"

module JBUpdater
  struct DetectedProduct
    getter name : String         # e.g. "RubyMine2025.2"
    getter code : String         # e.g. "RM"
    getter ide_path : String?    # e.g. "/Applications/RubyMine2025.2.app" or install dir
    getter config_dir : String?  # e.g. "~/Library/.../RubyMine2025.2"
    getter plugins_dir : String? # e.g. ".../plugins"

    def initialize(@name : String, @code : String, @ide_path : String?, @config_dir : String?, @plugins_dir : String?)
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

          config_base = Utils.jetbrains_config_base
          config_dir = Dir.glob(File.join(config_base, "#{name}*")).first?
          plugins_dir = config_dir ? File.join(config_dir, "plugins") : nil

          products << DetectedProduct.new(
            name: name,
            code: code,
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
            plugins_dir = File.join(full, "plugins")

            products << DetectedProduct.new(
              name: name,
              code: code,
              ide_path: nil, # install path is not trivial to detect; leave nil
              config_dir: full,
              plugins_dir: Dir.exists?(plugins_dir) ? plugins_dir : nil
            )
          end
        end
      {% elsif flag?(:win32) %}
        # Windows: detect from %APPDATA%\JetBrains config base
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
            plugins_dir = File.join(full, "plugins")

            products << DetectedProduct.new(
              name: name,
              code: code,
              ide_path: nil, # install path varies (Program Files/Toolbox/etc.)
              config_dir: full,
              plugins_dir: Dir.exists?(plugins_dir) ? plugins_dir : nil
            )
          end
        end
      {% end %}

      products
    end

    private def infer_code(name : String) : String
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

      key = name.gsub(/\d+.*/, "") # strip year/build
      mapping[key] || name[0, 2].upcase
    end
  end
end
