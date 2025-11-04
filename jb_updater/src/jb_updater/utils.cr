require "file_utils"

module JBUpdater
  module Utils
    INF = Float64::INFINITY

    # --------------------------------------------------------------------------
    # General utilities
    # --------------------------------------------------------------------------

    def self.run_cmd(cmd : String, *args : String) : {String, Process::Status}
      io = IO::Memory.new
      status = Process.run(cmd, args: args, output: io, error: io)
      {io.to_s, status}
    end

    def self.safe(str : String) : String
      str.gsub(/[^A-Za-z0-9_.-]/, "_")
    end

    def self.unzip_available? : Bool
      status = Process.run("which",
        args: ["unzip"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.success?
    end

    def self.extract_zip(zip_path : String, dest_dir : String) : Nil
      raise "'unzip' not found" unless unzip_available?
      tmp_root = File.join(Dir.tempdir,
        "jb-plg-#{Time.utc.to_unix}-#{Random::Secure.hex(4)}")
      FileUtils.mkdir_p(tmp_root)

      begin
        status = Process.run("unzip", args: ["-qq", "-o", zip_path, "-d", tmp_root])
        raise "unzip failed for #{zip_path}" unless status.success?

        entries = Dir.children(tmp_root).reject(&.==("__MACOSX"))
        root = if entries.size == 1 && File.directory?(File.join(tmp_root, entries.first))
                 File.join(tmp_root, entries.first)
               else
                 tmp_root
               end

        if File.exists?(dest_dir)
          backup = "#{dest_dir}.bak.#{Time.utc.to_unix}"
          FileUtils.mv(dest_dir, backup)
          puts "Backed up: #{dest_dir} -> #{backup}"
        end

        FileUtils.mkdir_p(File.dirname(dest_dir))
        FileUtils.mv(root, dest_dir)
      ensure
        FileUtils.rm_rf(tmp_root)
      end
    end

    # --------------------------------------------------------------------------
    # Build / version helpers
    # --------------------------------------------------------------------------

    def self.parse_build_string(str : String) : Array(Float64)
      return [0.0, 0.0, 0.0] if str.empty?
      core = str.gsub(/^[A-Z]+-/, "")
      parts = core.split('.', 3).map { |p| p == "*" ? INF : p.to_f }
      parts.fill(0.0, parts.size...3)
    end

    def self.build_in_range?(build_str : String, since_str : String?, until_str : String?) : Bool
      b = parse_build_string(build_str)
      s = since_str ? parse_build_string(since_str) : [0.0, 0.0, 0.0]
      u = until_str ? parse_build_string(until_str) : [INF, INF, INF]
      (s <= b) && (b <= u)
    end

    def self.escape(str : String) : String
      URI.encode_path_segment(str).gsub("%20", "+")
    end

    # --------------------------------------------------------------------------
    # JetBrains directory helpers
    # --------------------------------------------------------------------------

    def self.resolve_product_folder(short_or_full : String) : String
      base_dir = jetbrains_config_base
      FileUtils.mkdir_p(base_dir) unless Dir.exists?(base_dir)

      short = short_or_full.strip
      pattern = /^#{Regex.escape(short)}(\d|$)/i

      # exact match first
      return short_or_full if Dir.exists?(File.join(base_dir, short_or_full))

      matches = [] of {String, Array(Float64)}

      begin
        Dir.each_child(base_dir) do |entry|
          next unless pattern.matches?(entry)
          tail = entry.sub(/^#{short}/i, "")
          next if tail.empty?
          parts = tail.split('.', 3)
          numbers = parts.map(&.to_f).fill(0.0, parts.size...3)
          matches << {entry, numbers}
        end
      rescue ex : File::NotFoundError
        # cope gracefully if base_dir didn't exist yet
        raise "No config folder found for product '#{short}' under #{base_dir}"
      end

      raise "No config folder found for product '#{short}' under #{base_dir}" if matches.empty?

      matches.max_by(&.[1])[0]
    end

    def self.expand_jetbrains_plugins_dir(base : String) : String
      path = File.join(jetbrains_config_base, base, "plugins")
      FileUtils.mkdir_p(path) unless Dir.exists?(path)
      path
    end

    # Base JetBrains configuration directory for current OS.
    def self.jetbrains_config_base : String
      {% if flag?(:darwin) %}
        home = ENV["HOME"]? || File.expand_path("~")
        File.join(home, "Library/Application Support/JetBrains")
      {% elsif flag?(:linux) %}
        home = ENV["HOME"]? || File.expand_path("~")
        File.join(home, ".local/share/JetBrains")
      {% elsif flag?(:win32) %}
        File.join(ENV["APPDATA"].to_s, "JetBrains")
      {% else %}
        raise "Unsupported OS at compile time"
      {% end %}
    end
  end
end
