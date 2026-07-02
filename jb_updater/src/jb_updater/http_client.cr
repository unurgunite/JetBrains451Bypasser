require "http/client"
require "uri"

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
      raise "Too many redirects: #{depth}" if depth > 5
      loc = response.headers["Location"]?
      raise "redirect without Location header for #{uri}" unless loc
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

    # Downloads a file to disk with streaming, progress tracking, and redirect handling.
    #
    # Follows HTTP 301/302 redirects (up to 5). Shows a TTY progress bar
    # unless suppressed via `no_tty_progress_bar=`. Fires `on_progress`
    # callbacks in 16 KB chunks.
    #
    # @param uri [URI] Resource to download
    # @param dest_path [String] Local file path to write to
    # @param depth [Int32] Internal redirect counter (do not pass)
    # @raise [RuntimeError] On too many redirects, missing Location header, or non-200 status
    def self.download(uri : URI, dest_path : String, depth = 0) : Nil
      raise "Too many redirects: #{depth}" if depth > 5
      fname = File.basename(dest_path)
      Log.info "Downloading: #{fname} ← #{uri}"
      notify_request("GET", uri.to_s)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}
      client = HTTP::Client.new(uri)
      client.read_timeout = 60.seconds
      client.connect_timeout = 15.seconds
      client.before_request(&.headers.merge!(headers))

      begin
        client.get(uri.request_target, headers: headers) do |response|
          case response.status_code
          when 200
            downloaded = stream_to_file(response, dest_path, fname)
            notify_download_complete(fname, dest_path, downloaded)
          when 301, 302
            follow_redirect(response, uri, dest_path, depth)
          else
            raise "HTTP #{response.status_code} #{response.status_message} for #{uri}"
          end
        end
      ensure
        client.close
      end
    end

    private def self.stream_to_file(response : HTTP::Client::Response, dest_path : String, fname : String) : Int64
      length_header = response.headers["Content-Length"]?
      total = length_header ? length_header.to_i64 : 0_i64
      Log.info "Download started: #{fname} (#{total > 0 ? Utils.format_bytes(total) : "unknown size"})"
      downloaded = 0_i64

      File.open(dest_path, "wb") do |file|
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
