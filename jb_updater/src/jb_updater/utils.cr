require "file_utils"
require "compress/zip"
require "compress/deflate"

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

    # Extracts a ZIP archive into a target directory using the pure-Crystal
    # `Compress::Zip` stdlib reader (no external `unzip` binary).
    #
    # Runs safely from background threads — unlike `Process.run` which
    # deadlocks in spawned threads on some Crystal versions.
    #
    # If the archive contains a single root directory its contents are
    # flattened into `dest_dir`. Existing directories are backed up
    # with a `.bak.<timestamp>` suffix.
    #
    # @param zip_path [String] Path to the ZIP file
    # @param dest_dir [String] Target installation directory
    # @raise [RuntimeError] If the archive cannot be read or extracted
    def self.extract_zip(zip_path : String, dest_dir : String) : Nil
      tmp_root = File.join(Dir.tempdir,
        "jb-plg-#{Time.utc.to_unix}-#{Random::Secure.hex(4)}")
      FileUtils.mkdir_p(tmp_root)

      begin
        extract_zip_entries(zip_path, tmp_root)

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

    # Parses the central directory of a zip and returns file entries
    # (name, method, compressed size, local header offset).
    #
    # Unlike `Compress::Zip`, this never touches DOS timestamps, so
    # archives with invalid timestamp fields (common on JetBrains
    # marketplace) are still readable.
    private def self.zip_file_entries(zip_path : String) : Array(Tuple(String, UInt16, UInt32, UInt32))
      file_bytes = File.open(zip_path, "rb", &.gets_to_end.to_slice)
      io = IO::Memory.new(file_bytes)
      le = IO::ByteFormat::LittleEndian

      eocd = -1
      search_from = [file_bytes.size - 65_557, 0].max
      i = file_bytes.size - 4
      while i >= search_from
        if file_bytes[i] == 0x50 && file_bytes[i + 1] == 0x4B &&
           file_bytes[i + 2] == 0x05 && file_bytes[i + 3] == 0x06
          eocd = i
          break
        end
        i -= 1
      end
      raise "Invalid zip: end of central directory not found" if eocd < 0

      io.pos = eocd + 10
      total = io.read_bytes(UInt16, le)
      io.pos = eocd + 16
      cd_offset = io.read_bytes(UInt32, le)
      raise "Invalid zip: bad central directory offset" if cd_offset >= file_bytes.size

      entries = Array(Tuple(String, UInt16, UInt32, UInt32)).new(total)

      io.pos = cd_offset.to_i
      total.times do
        sig = io.read_bytes(UInt32, le)
        raise "Invalid zip: bad central directory entry" unless sig == 0x02014B50
        io.pos += 2 + 2 + 2 # version made / needed / flags
        method = io.read_bytes(UInt16, le)
        io.pos += 2 + 2 + 4 # mod time / date / crc
        comp_size = io.read_bytes(UInt32, le)
        io.pos += 4 # uncomp size
        name_len = io.read_bytes(UInt16, le)
        extra_len = io.read_bytes(UInt16, le)
        comment_len = io.read_bytes(UInt16, le)
        io.pos += 2 + 2 + 4 # disk start / internal / external attrs
        offset = io.read_bytes(UInt32, le)
        name_bytes = Bytes.new(name_len)
        io.read_fully(name_bytes)
        io.pos += extra_len + comment_len
        name = String.new(name_bytes)
        next if name.ends_with?('/') || name.starts_with?("__MACOSX/") || name.includes?("..")
        entries << {name, method, comp_size, offset}
      end

      entries
    end

    # Extracts a zip archive to a directory using a byte-level reader.
    private def self.extract_zip_entries(zip_path : String, dest_dir : String) : Nil
      entries = zip_file_entries(zip_path)

      entries.each do |name, method, comp_size, offset|
        target = File.join(dest_dir, name)
        FileUtils.mkdir_p(File.dirname(target))
        File.open(target, "w") do |out_file|
          zip_entry_bytes(zip_path, method, comp_size, offset) do |io|
            if method == 0
              IO.copy(io, out_file, comp_size)
            else
              reader = Compress::Deflate::Reader.new(io)
              IO.copy(reader, out_file)
            end
          end
        end
      end
    end

    # Yields a deflate/stored entry's decompressed bytes stream.
    private def self.zip_entry_bytes(zip_path : String, method : UInt16, comp_size : UInt32, offset : UInt32, & : IO ->)
      file_bytes = File.open(zip_path, "rb", &.gets_to_end.to_slice)
      io = IO::Memory.new(file_bytes)
      le = IO::ByteFormat::LittleEndian

      io.pos = offset.to_i
      sig = io.read_bytes(UInt32, le)
      raise "Invalid zip: bad local header" unless sig == 0x04034B50
      io.pos += 2 + 2 + 2 + 2 + 2 + 4 + 4 + 4 # version/flag/method/time/date/crc/sizes
      name_len = io.read_bytes(UInt16, le)
      extra_len = io.read_bytes(UInt16, le)
      io.pos += name_len + extra_len

      if method == 0
        yield io
      elsif method == 8
        comp_data = Bytes.new(comp_size)
        io.read_fully(comp_data)
        yield IO::Memory.new(comp_data)
      else
        raise "Invalid zip: unsupported compression method #{method}"
      end
    end

    # Reads a single file out of a zip archive as a String.
    #
    # Returns `nil` if the entry is missing or cannot be decoded. Safe to
    # call from background threads (no `Process.run`, no `Compress::Zip`
    # timestamp bug).
    def self.read_zip_file(zip_path : String, inner_path : String) : String?
      entry = zip_file_entries(zip_path).find { |(name, _, _, _)| name == inner_path }
      return unless entry
      _, method, comp_size, offset = entry
      result = String.build do |str|
        zip_entry_bytes(zip_path, method, comp_size, offset) do |io|
          if method == 0
            IO.copy(io, str, comp_size)
          else
            reader = Compress::Deflate::Reader.new(io)
            IO.copy(reader, str)
          end
        end
      end
      result
    rescue
      nil
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

    # Generates older build identifiers for the same product code.
    #
    # Marketplace APIs filter plugins by strict build compatibility
    # (e.g. DocScribe declares only `261.*`, skipping RubyMine 2026.2).
    # This helper walks backwards in yearly/monor increments so callers
    # can search/download across slightly older compatible builds.
    #
    # Example: `"RM-262"` → `["RM-261", "RM-253", "RM-252", "RM-251", ...]`
    #
    # @param build_str [String] Current build (e.g. `"RM-262.9437.192"`)
    # @param limit [Int32] Maximum number of older builds to produce
    # @return [Array(String)] Older build strings for the same product
    def self.previous_builds(build_str : String, limit : Int32 = 8) : Array(String)
      m = build_str.match(/^([A-Z]+)-(\d{3})/)
      return [] of String unless m
      code = m[1]
      year = m[2][0, 2].to_i
      minor = m[2][2].to_i
      return [] of String if minor.zero?

      result = [] of String
      result << "#{code}-#{year}#{minor - 1}" if minor > 1

      (year - 1).downto(year - 4) do |y|
        break if result.size >= limit
        [3, 2, 1].each do |alt_minor|
          result << "#{code}-#{y}#{alt_minor}"
          break if result.size >= limit
        end
      end

      result[0...limit]
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

    # Maps a product name to its JetBrains product code.
    #
    # Strips trailing version numbers and spaces, matches the base
    # name case-insensitively, and returns the short code
    # (e.g. `"RubyMine2025.2"` -> `"RM"`, `"ruby"` -> `"RM"`).
    # Unknown names fall back to the first two uppercase characters.
    #
    # @param name [String] Product name (e.g. `"RubyMine2025.2"` or `"phpstorm"`)
    # @return [String] Product code (e.g. `"RM"`)
    def self.product_code(name : String) : String
      mapping = {
        "ruby"      => "RM",
        "rubymine"  => "RM",
        "rm"        => "RM",
        "webstorm"  => "WS",
        "ws"        => "WS",
        "pycharm"   => "PY",
        "py"        => "PY",
        "clion"     => "CL",
        "cl"        => "CL",
        "goland"    => "GO",
        "go"        => "GO",
        "intellij"  => "IU",
        "idea"      => "IU",
        "iu"        => "IU",
        "phpstorm"  => "PS",
        "ps"        => "PS",
        "rider"     => "RD",
        "rd"        => "RD",
        "datagrip"  => "DG",
        "dg"        => "DG",
        "dataspell" => "DS",
        "ds"        => "DS",
        "aqua"      => "QA",
        "appcode"   => "AC",
      }

      key = name.gsub(/[\d ].*/, "").downcase
      mapping[key]? || name[0, 2].upcase
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
          next if backup_folder?(entry)
          tail = entry.sub(/^#{short}/i, "")
          next if tail.empty?
          numbers = version_numbers(tail)
          matches << {entry, numbers}
        end
      rescue File::NotFoundError
        raise "No config folder found for product '#{short}' under #{base_dir}"
      end

      raise "No config folder found for product '#{short}' under #{base_dir}" if matches.empty?

      matches.max_by(&.[1])[0]
    end

    # Returns the newest versioned config directory for a product name.
    #
    # Unlike {resolve_product_folder} this is non-destructive (never creates
    # the base dir) and returns an absolute path of a *matching* folder, or
    # `nil` when no versioned folder exists. Backup folders are skipped.
    #
    # This is used by {DetectProducts.all} so a product with multiple config
    # versions (e.g. `RubyMine2025.3`, `RubyMine2026.1`, `RubyMine2026.2`)
    # resolves to the **latest** one instead of an arbitrary glob match.
    #
    # @param base_dir [String] JetBrains config base directory
    # @param name [String] Product name (e.g. `"RubyMine"`)
    # @return [String?] Absolute path of the newest matching dir, or `nil`
    def self.latest_versioned_config_dir(base_dir : String, name : String) : String?
      return unless Dir.exists?(base_dir)

      pattern = /^#{Regex.escape(name)}(\d|$)/i
      matches = [] of {String, Array(Float64)}

      Dir.each_child(base_dir) do |entry|
        next unless pattern.matches?(entry)
        next if backup_folder?(entry)
        tail = entry.sub(/^#{name}/i, "")
        matches << {entry, tail.empty? ? [0.0, 0.0, 0.0] : version_numbers(tail)}
      end

      return if matches.empty?

      best = matches.max_by(&.[1])[0]
      File.join(base_dir, best)
    end

    # Extracts up to three version numbers from a product folder suffix.
    #
    # Tolerates non-numeric fragments (e.g. `"2025.2-backup"` → `[2025.0, 2.0]`)
    # instead of raising on `String#to_f`.
    #
    # @param tail [String] Folder name suffix after the product name
    # @return [Array(Float64)] Three-element version array
    def self.version_numbers(tail : String) : Array(Float64)
      parts = tail.split('.', 3)
      numbers = parts.map do |part|
        match = part.match(/\A[^0-9]*(\d+(?:\.\d+)?)/)
        match ? match[1].to_f : 0.0
      end
      numbers.push(0.0, 0.0, 0.0)[0, 3]
    end

    # Detects backup-style folder names produced by updater backups.
    #
    # Matches `.bak`, `.bak.<timestamp>`, `-backup`, and `_backup` suffixes.
    #
    # @param entry [String] Folder name
    # @return [Bool] `true` if the name looks like a backup folder
    def self.backup_folder?(entry : String) : Bool
      entry.matches?(/(\.bak|[-_]?backup)/i)
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
