require "json"
require "./utils"

module JBUpdater
  struct DetectedProduct
    getter name : String         # e.g. "RubyMine2025.2"
    getter code : String         # e.g. "RM"
    getter ide_path : String?    # e.g. "/Applications/RubyMine2025.2.app"
    getter config_dir : String?  # e.g. "~/Library/.../RubyMine2025.2"
    getter plugins_dir : String? # e.g. ".../plugins"

    def initialize(@name : String, @code : String, @ide_path : String?, @config_dir : String?, @plugins_dir : String?)
    end
  end

  module DetectProducts
    extend self

    def all : Array(DetectedProduct)
      products = [] of DetectedProduct

      {% if flag?(:darwin) %}
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
        # TODO: implement detection for Linux (e.g., under /opt, /usr/share)
      {% elsif flag?(:win32) %}
        # TODO: implement detection for Windows
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
