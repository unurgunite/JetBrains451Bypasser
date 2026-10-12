require "http/client"
require "uri"
require "digest/md5"
require "digest/sha256"

module JBUpdater
  # Low-level HTTP client used for plugin and IDE downloads.
  #
  # Provides blocking HEAD/GET requests and streaming file downloads
  # with redirect following (up to 5 hops), TTY progress bar, and
  # optional callbacks for request logging and progress tracking.
  class HTTPClient
    # Default User-Agent header sent with every request.
    USER_AGENT = "jb-updater/crystal/1.0 (+https://github.com/unurgunite)"

    @@no_tty_progress_bar : Bool = false

    # Enables or disables the terminal progress bar during downloads.
    #
    # Set to `true` when output is captured (e.g. by the GUI) to avoid
    # ANSI escape sequences in logs.
    #
    # @param on [Bool] `true` to suppress the TTY progress bar
    def self.no_tty_progress_bar=(on : Bool)
      @@no_tty_progress_bar = on
    end

    # Returns whether the TTY progress bar is suppressed.
    #
    # @return [Bool]
    def self.no_tty_progress_bar? : Bool
      @@no_tty_progress_bar
    end

    @@request_callback : Proc(String, String, Nil)? = nil

    # Registers a callback invoked before each outgoing HTTP request.
    #
    # The callback receives the HTTP method and the full URL as strings.
    #
    # @param cb [Proc(String, String, Nil)?] Callback or `nil` to unregister
    def self.on_request=(cb : Proc(String, String, Nil)?)
      @@request_callback = cb
    end

    private def self.notify_request(method : String, url : String)
      @@request_callback.try(&.call(method, url))
    end

    @@progress_callback : Proc(Int64, Int64, Nil)? = nil

    # Registers a callback invoked periodically during file downloads.
    #
    # The callback receives the number of bytes downloaded so far and
    # the total content length (if known).
    #
    # @param cb [Proc(Int64, Int64, Nil)?] Progress callback or `nil` to unregister
    def self.on_progress=(cb : Proc(Int64, Int64, Nil)?)
      @@progress_callback = cb
    end

    private def self.notify_progress(downloaded : Int64, total : Int64)
      @@progress_callback.try(&.call(downloaded, total))
    end

    # Sends a HEAD or GET request and returns the response.
    #
    # Timeouts: 30 s read, 15 s connect.
    #
    # @param url [String] The target URL
    # @param method [Symbol] `:head` or `:get`
    # @return [HTTP::Client::Response]
    def self.head_or_get(url : String, method : Symbol = :get) : HTTP::Client::Response
      uri = URI.parse(url)
      notify_request(method.to_s.upcase, url)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = HTTP::Client.new(uri)
      client.read_timeout = 30.seconds
      client.connect_timeout = 15.seconds
      client.before_request(&.headers.merge!(headers))

      begin
        case method
        when :head
          client.head(uri.request_target)
        else
          client.get(uri.request_target)
        end
      ensure
        client.close
      end
    end

    # Follows an HTTP redirect by parsing the Location header.
    private def self.follow_redirect(response : HTTP::Client::Response, uri : URI, dest_path : String, depth : Int32) : Nil
      raise RuntimeError.new("Too many redirects: #{depth}") if depth > 5
      loc = response.headers["Location"]?
      raise RuntimeError.new("redirect without Location header for #{uri}") unless loc
      next_uri = URI.parse(loc)
      unless next_uri.absolute?
        next_uri = URI.new(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.port,
          path: loc,
        )
      end
      download(next_uri, dest_path, depth + 1)
    end

    # Maximum download attempts (initial try + retries).
    MAX_RETRIES = 3

    # Base delay (seconds) for exponential backoff between retries.
    RETRY_BASE_DELAY = 1.0

    # Downloads a file to disk with streaming, progress tracking, and redirect handling.
    #
    # Follows HTTP 301/302 redirects (up to 5). Shows a TTY progress bar
    # unless suppressed via `no_tty_progress_bar=`. Fires `on_progress`
    # callbacks in 16 KB chunks.
    #
    # Retries transient failures (connection errors, 5xx, 429) up to
    # `MAX_RETRIES` times with exponential backoff. Resumes partial
    # downloads via `Range` requests when the server supports them.
    # Writes to `<dest>.part` and renames atomically on success, so a
    # failed download never leaves a corrupt file at `dest_path`.
    #
    # @param uri [URI] Resource to download
    # @param dest_path [String] Local file path to write to
    # @param depth [Int32] Internal redirect counter (do not pass)
    # @param expected_sha256 [String?] Optional hex SHA-256 to verify after download
    # @raise [RuntimeError] On too many redirects, missing Location header, non-200 status, or checksum mismatch
    def self.download(uri : URI, dest_path : String, depth = 0, expected_sha256 : String? = nil) : Nil
      raise RuntimeError.new("Too many redirects: #{depth}") if depth > 5
      attempt_download(uri, dest_path, depth, expected_sha256)
    end

    private def self.attempt_download(uri : URI, dest_path : String, depth : Int32, expected_sha256 : String?) : Nil
      last_error : Exception? = nil
      (1..MAX_RETRIES).each do |attempt|
        begin
          single_download(uri, dest_path, depth, expected_sha256)
          return
        rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error
          last_error = ex
        rescue ex : RuntimeError
          # Retry only transient HTTP failures (5xx, 429); anything else raises immediately.
          raise ex unless ex.message =~ /HTTP (429|5\d\d)/
          last_error = ex
        end
        if attempt < MAX_RETRIES
          delay = RETRY_BASE_DELAY * (2 ** (attempt - 1))
          Log.warn "Download attempt #{attempt}/#{MAX_RETRIES} failed (#{last_error.try(&.message)}), retrying in #{delay}s..."
          sleep delay.seconds
        end
      end
      last = last_error
      raise(last) if last
      raise RuntimeError.new("Download failed for #{uri}")
    end

    private def self.single_download(uri : URI, dest_path : String, depth : Int32, expected_sha256 : String?) : Nil
      raise RuntimeError.new("Too many redirects: #{depth}") if depth > 5
      fname = File.basename(dest_path)
      part_path = "#{dest_path}.part"
      Log.info "Downloading: #{fname} ← #{uri}"
      notify_request("GET", uri.to_s)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      # Resume: if a partial file exists, ask the server for the remainder.
      resume_from = File.exists?(part_path) ? File.size(part_path) : 0_i64
      if resume_from > 0
        headers["Range"] = "bytes=#{resume_from}-"
        Log.info "Resuming #{fname} from #{Utils.format_bytes(resume_from)}"
      end

      client = HTTP::Client.new(uri)
      client.read_timeout = 60.seconds
      client.connect_timeout = 15.seconds
      client.before_request(&.headers.merge!(headers))

      begin
        client.get(uri.request_target, headers: headers) do |response|
          case response.status_code
          when 200
            # Server ignored Range (or fresh download): restart from scratch.
            File.delete(part_path) if resume_from > 0
            downloaded = stream_to_file(response, part_path, fname, 0_i64)
            finish_download(part_path, dest_path, fname, downloaded, expected_sha256, response.headers["ETag"]?)
          when 206
            downloaded = stream_to_file(response, part_path, fname, resume_from)
            finish_download(part_path, dest_path, fname, downloaded, expected_sha256, nil)
          when 301, 302
            follow_redirect(response, uri, dest_path, depth)
          else
            raise RuntimeError.new("HTTP #{response.status_code} #{response.status_message} for #{uri}")
          end
        end
      ensure
        client.close
      end
    end

    # Extracts the MD5 hex from an ETag header, or `nil`.
    #
    # Only plain 32-hex ETags (single-part S3 objects) qualify;
    # multipart (`<hex>-<n>`) and weak (`W/`) ETags are skipped.
    private def self.plain_etag_md5(etag : String?) : String?
      return unless etag
      clean = etag.strip.strip('"')
      return unless clean =~ /\A[0-9a-fA-F]{32}\z/
      clean.downcase
    end

    # Verifies file SHA-256 against the expected hex.
    private def self.verify_sha256(path : String, fname : String, expected : String) : Nil
      digest = Digest::SHA256.new
      hash_file(path, digest)
      actual = digest.final.hexstring
      unless actual.downcase == expected.downcase
        File.delete(path) rescue nil
        raise RuntimeError.new("SHA-256 mismatch for #{fname}: expected #{expected}, got #{actual}")
      end
      Log.info "Checksum OK (SHA-256): #{fname}"
    end

    # Verifies file MD5 against the ETag hex.
    private def self.verify_md5(path : String, fname : String, expected : String) : Nil
      digest = Digest::MD5.new
      hash_file(path, digest)
      actual = digest.final.hexstring
      unless actual.downcase == expected.downcase
        File.delete(path) rescue nil
        raise RuntimeError.new("MD5 mismatch for #{fname}: expected #{expected}, got #{actual}")
      end
      Log.info "Checksum OK (ETag MD5): #{fname}"
    end

    # Feeds a file into a digest in 64 KB chunks.
    private def self.hash_file(path : String, digest : Digest) : Nil
      File.open(path, "rb") do |file|
        buf = Bytes.new(65536)
        loop do
          n = file.read(buf)
          break if n == 0
          digest.update(buf[0, n])
        end
      end
    end

    #
    # Falls back to ETag MD5 verification: S3/CloudFront return the file
    # MD5 as a plain 32-hex ETag for single-part objects. Multipart ETags
    # (`<hex>-<n>`) are skipped. No verification on resumed (206) downloads
    # since the ETag describes the whole object, not the range.
    private def self.finish_download(part_path : String, dest_path : String, fname : String, downloaded : Int64, expected_sha256 : String?, etag : String? = nil) : Nil
      if sha = expected_sha256
        verify_sha256(part_path, fname, sha)
      elsif etag_md5 = plain_etag_md5(etag)
        verify_md5(part_path, fname, etag_md5)
      end
      # Windows rename fails when the target exists (POSIX overwrites),
      # so remove a pre-existing dest (e.g. File.tempfile in specs).
      File.delete(dest_path) if File.exists?(dest_path)
      File.rename(part_path, dest_path)
      notify_download_complete(fname, dest_path, downloaded)
    end

    private def self.stream_to_file(response : HTTP::Client::Response, dest_path : String, fname : String, start_at : Int64 = 0_i64) : Int64
      length_header = response.headers["Content-Length"]?
      total = length_header ? length_header.to_i64 + start_at : 0_i64
      Log.info "Download started: #{fname} (#{total > 0 ? Utils.format_bytes(total) : "unknown size"})"
      downloaded = start_at

      File.open(dest_path, start_at > 0 ? "ab" : "wb") do |file|
        bar_width = 40

        if stream = response.body_io
          buf = Bytes.new(16384)
          loop do
            read_bytes = stream.read(buf)
            break if read_bytes == 0
            file.write(buf[0, read_bytes])
            downloaded += read_bytes
            notify_progress(downloaded, total)

            if total > 0 && !HTTPClient.no_tty_progress_bar?
              progress = (downloaded.to_f / total * bar_width)
                .clamp(0, bar_width).to_i
              percent = (downloaded.to_f / total * 100).round(1)
              bar = "#" * progress + " " * (bar_width - progress)
              print "\r[#{bar}] #{percent}%"
              STDOUT.flush
            end
          end
        end
      end

      Log.info "Download complete: #{fname} (#{Utils.format_bytes(downloaded)})"
      downloaded
    end

    private def self.notify_download_complete(fname : String, dest_path : String, downloaded : Int64)
      if HTTPClient.no_tty_progress_bar?
        puts "Download complete: #{dest_path}"
      else
        puts "\rDownload complete#{" " * 40}"
      end
    end

    # Replaces the plugin download host with a custom CDN host.
    #
    # Only applies when the original host matches `plugins.jetbrains.com`
    # and the path starts with `/files/`.
    #
    # @param uri [URI] Original download URI
    # @param downloads_host [String?] Custom CDN hostname or `nil` to disable
    # @return [URI] Possibly modified URI
    def self.override_plugin_repo_host(uri : URI, downloads_host : String?) : URI
      return uri if downloads_host.nil? || downloads_host.empty?
      return uri unless uri.host =~ /^plugins\.jetbrains\.com$/i &&
                        uri.path.starts_with?("/files/")
      URI.new(
        scheme: "https",
        host: downloads_host,
        path: uri.path,
        query: uri.query
      )
    end

    # Replaces the IDE download host with a custom CDN host.
    #
    # Defaults to `download-cdn.jetbrains.com`. Only applies when the
    # original host matches `download.jetbrains.com`.
    #
    # @param uri [URI] Original download URI
    # @param downloads_host [String?] Custom hostname (defaults to `download-cdn.jetbrains.com`)
    # @return [URI] Possibly modified URI
    def self.override_ide_repo_host(uri : URI, downloads_host : String? = nil) : URI
      host = downloads_host || "download-cdn.jetbrains.com"
      return uri unless uri.host =~ /^download\.jetbrains\.com$/i
      URI.new(
        scheme: "https",
        host: host,
        path: uri.path,
        query: uri.query
      )
    end
  end
end
