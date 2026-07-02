require "file_utils"

module JBUpdater
  # Shared utility methods used across the codebase.
  #
  # Provides helpers for running shell commands, string sanitisation,
  # ZIP extraction, version comparison, URL escaping, and JetBrains
  # directory resolution.
  module Utils
    # Infinity constant used in version range comparisons.
    INF = Float64::INFINITY

    # --------------------------------------------------------------------------
    # General utilities
    # --------------------------------------------------------------------------

    # Runs a shell command and captures its combined output.
    #
    # @param cmd [String] The executable name or path
    # @param args [String...] Command-line arguments
    # @return [{String, Process::Status}] Tuple of captured stdout+stderr and exit status
    def self.run_cmd(cmd : String, *args : String) : {String, Process::Status}
      io = IO::Memory.new
      status = Process.run(cmd, args: args, output: io, error: io)
      {io.to_s, status}
    end

    # Replaces characters unsafe for filenames with underscores.
    #
    # Only `A-Za-z0-9_.-` are kept; everything else becomes `_`.
    #
    # @param str [String] Input filename / path fragment
    # @return [String] Sanitised string
    def self.safe(str : String) : String
      str.gsub(/[^A-Za-z0-9_.-]/, "_")
    end

    # Checks whether the `unzip` tool is available on `$PATH`.
    #
    # @return [Bool] `true` if `which unzip` succeeds
    def self.unzip_available? : Bool
      status = Process.run("which",
        args: ["unzip"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.success?
    end

    # Extracts a ZIP archive into a target directory.
    #
    # If the archive contains a single root directory its contents are
    # flattened into `dest_dir`. Existing directories are backed up
    # with a `.bak.<timestamp>` suffix.
    #
    # @param zip_path [String] Path to the ZIP file
    # @param dest_dir [String] Target installation directory
    # @raise [RuntimeError] If `unzip` is not found or the command fails
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

    # Parses a version string into a 3-element float array for comparison.
    #
    # Strips a leading product-code prefix (e.g. `RM-252` → `252`),
    # splits on `.`, and pads to 3 parts. A wildcard `*` is expanded
    # to `Float64::INFINITY`.
    #
    # @param str [String] Version string (`"2025.1.2"`, `"RM-252"`, or `"2025.1.*"`)
    # @return [Array(Float64)] Three-element array `[major, minor, patch]`
    def self.parse_build_string(str : String) : Array(Float64)
      return [0.0, 0.0, 0.0] if str.empty?
      core = str.gsub(/^[A-Z]+-/, "")
      parts = core.split('.', 3).map { |part| part == "*" ? INF : part.to_f }
      parts.fill(0.0, parts.size...3)
    end

    # Checks whether a build version falls within a `[since, until]` range.
    #
    # A `nil` bound is treated as unbounded (0 for lower, infinity for upper).
    #
    # @param build_str [String] The build to check
    # @param since_str [String?] Lower bound (inclusive) or `nil`
    # @param until_str [String?] Upper bound (inclusive) or `nil`
    # @return [Bool] `true` if `since ≤ build ≤ until`
    def self.build_in_range?(build_str : String, since_str : String?, until_str : String?) : Bool
      b = parse_build_string(build_str)
      s = since_str ? parse_build_string(since_str) : [0.0, 0.0, 0.0]
      u = until_str ? parse_build_string(until_str) : [INF, INF, INF]
      (s <= b) && (b <= u)
    end

    # URL-encodes a path segment, replacing `%20` with `+`.
    #
    # @param str [String] Raw path segment
    # @return [String] Encoded string
    def self.escape(str : String) : String
      URI.encode_path_segment(str).gsub("%20", "+")
    end

    # Formats a byte count into a human-readable string.
    #
    # Uses B, KB, MB, or GB units with two decimal places.
    #
    # @param bytes [Int64] Byte count
    # @return [String] e.g. `"1.50 MB"` or `"920 B"`
    def self.format_bytes(bytes : Int64) : String
      if bytes >= 1_000_000_000
        "#{(bytes.to_f / 1_000_000_000).round(2)} GB"
      elsif bytes >= 1_000_000
        "#{(bytes.to_f / 1_000_000).round(2)} MB"
      elsif bytes >= 1_000
        "#{(bytes.to_f / 1_000).round(2)} KB"
      else
        "#{bytes} B"
      end
    end

    # --------------------------------------------------------------------------
    # JetBrains directory helpers
    # --------------------------------------------------------------------------

    # Resolves a product folder name under the JetBrains config base.
    #
    # Supports exact names (e.g. `"RubyMine2025.2"`) and short names
    # (e.g. `"WebStorm"` picks the latest installed version).
    #
    # @param short_or_full [String] Product folder name or short prefix
    # @return [String] Full folder name with version suffix
    # @raise [RuntimeError] If no matching folder is found
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
        raise "No config folder found for product '#{short}' under #{base_dir}"
      end

      raise "No config folder found for product '#{short}' under #{base_dir}" if matches.empty?

      matches.max_by(&.[1])[0]
    end

    # Returns the `plugins` subdirectory for a JetBrains product, creating it if needed.
    #
    # @param base [String] Product folder name (e.g. `"WebStorm2025.2"`)
    # @return [String] Absolute path to the plugins directory
    def self.expand_jetbrains_plugins_dir(base : String) : String
      path = File.join(jetbrains_config_base, base, "plugins")
      FileUtils.mkdir_p(path) unless Dir.exists?(path)
      path
    end

    # Expands a leading `~` or `~/` to the current user's home directory.
    #
    # Only the simple current-user case is supported (`~` or `~/path`);
    # `~user` style paths are returned unchanged.
    #
    # @param path [String] Path that may start with `~`
    # @return [String] Expanded path
    def self.expand_tilde(path : String) : String
      return path unless path.starts_with?("~")

      home = ENV["HOME"]? || File.expand_path("~")
      return home if path == "~"

      if path.starts_with?("~/")
        File.join(home, path[2..])
      else
        path
      end
    end

    # Returns the JetBrains configuration root directory for the current OS.
    #
    # - **macOS**:  `~/Library/Application Support/JetBrains`
    # - **Linux**:  `~/.local/share/JetBrains`
    # - **Windows**: `%APPDATA%/JetBrains`
    #
    # @return [String] Platform-specific config base path
    # @raise [RuntimeError] On unsupported platforms (compile-time)
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
