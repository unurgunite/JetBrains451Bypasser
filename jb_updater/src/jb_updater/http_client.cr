require "http/client"
require "uri"

module JBUpdater
  class HTTPClient
    USER_AGENT = "jb-updater/crystal/1.0 (+https://github.com/unurgunite)"

    # Default: show TTY progress bars (CLI friendly)
    @@no_tty_progress_bar : Bool = false

    def self.no_tty_progress_bar=(on : Bool)
      @@no_tty_progress_bar = on
    end

    def self.no_tty_progress_bar? : Bool
      @@no_tty_progress_bar
    end

    # Optional callback invoked before each HTTP request
    @@request_callback : Proc(String, String, Nil)? = nil

    def self.on_request=(cb : Proc(String, String, Nil)?)
      @@request_callback = cb
    end

    private def self.notify_request(method : String, url : String)
      @@request_callback.try(&.call(method, url))
    end

    # Optional callback for download progress (downloaded_bytes, total_bytes)
    @@progress_callback : Proc(Int64, Int64, Nil)? = nil

    def self.on_progress=(cb : Proc(Int64, Int64, Nil)?)
      @@progress_callback = cb
    end

    private def self.notify_progress(downloaded : Int64, total : Int64)
      @@progress_callback.try(&.call(downloaded, total))
    end

    # ----------------------------------------------------------------------
    # Perform a HEAD or GET and return the Response
    # ----------------------------------------------------------------------
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

    # ----------------------------------------------------------------------
    # Download a file with redirect support and a simple progress bar
    # ----------------------------------------------------------------------
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
            if HTTPClient.no_tty_progress_bar?
              puts "Download complete: #{dest_path}"
            else
              puts "\rDownload complete#{" " * 40}"
            end
          when 301, 302
            loc = response.headers["Location"]?
            Log.info "Redirect #{depth + 1}: #{uri} → #{loc}"
            if loc
              next_uri = URI.parse(loc)
              unless next_uri.absolute?
                next_uri = URI.new(
                  scheme: uri.scheme,
                  host: uri.host,
                  port: uri.port,
                  path: loc
                )
              end
              return download(next_uri, dest_path, depth + 1)
            else
              raise "redirect without Location header for #{uri}"
            end
          else
            raise "HTTP #{response.status_code} #{response.status_message} for #{uri}"
          end
        end
      ensure
        client.close
      end
    end

    # ----------------------------------------------------------------------
    # Replace JetBrains plugin download host (for CDN workaround)
    # ----------------------------------------------------------------------
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

    # ----------------------------------------------------------------------
    # Replace JetBrains IDE download host (for CDN/proxy)
    # ----------------------------------------------------------------------
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
