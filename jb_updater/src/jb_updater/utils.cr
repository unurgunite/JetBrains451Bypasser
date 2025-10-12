require "file_utils"

module JBUpdater
  module Utils
    INF = Float64::INFINITY

    def self.run_cmd(cmd : String, *args : String) : {String, Process::Status}
      io = IO::Memory.new
      status = Process.run(cmd, args: args.to_a, output: io, error: io)
      {io.to_s, status}
    end

    def self.safe(str : String) : String
      str.gsub(/[^A-Za-z0-9_.-]/, "_")
    end

    def self.unzip_available? : Bool
      status = Process.run("which", args: ["unzip"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.success?
    end

    def self.extract_zip(zip_path : String, dest_dir : String) : Nil
      raise "'unzip' not found" unless unzip_available?
      tmp_root = File.join(Dir.tempdir, "jb-plg-#{Time.utc.to_unix}-#{Random::Secure.hex(4)}")
      FileUtils.mkdir_p(tmp_root)

      begin
        status = Process.run("unzip", args: ["-qq", "-o", zip_path, "-d", tmp_root])
        raise "unzip failed for #{zip_path}" unless status.success?

        entries = Dir.children(tmp_root).reject { |e| e == "__MACOSX" }
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

    def self.parse_build_string(str : String) : Array(Float64)
      return [0.0, 0.0, 0.0] if str.empty?
      core = str.gsub(/^[A-Z]+-/, "")
      parts = core.split('.', 3).map do |p|
        p == "*" ? INF : p.to_f
      end
      parts.fill(0.0, parts.size...3)
    end

    def self.build_in_range?(build_str : String, since_str : String?, until_str : String?) : Bool
      b = parse_build_string(build_str)
      s = since_str ? parse_build_string(since_str) : [0.0, 0.0, 0.0]
      u = until_str ? parse_build_string(until_str) : [INF, INF, INF]
      (s <= b) && (b <= u)
    end

    def self.escape(str : String) : String
      # Use stdlib’s URI.encode_path_segment, then convert spaces to '+'
      URI.encode_path_segment(str).gsub("%20", "+")
    end
  end
end
