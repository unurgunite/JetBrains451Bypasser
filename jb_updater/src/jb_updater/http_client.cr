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

    # ----------------------------------------------------------------------
    # Perform a HEAD or GET and return the Response
    # ----------------------------------------------------------------------
    def self.head_or_get(url : String, method : Symbol = :get) : HTTP::Client::Response
      uri = URI.parse(url)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = HTTP::Client.new(uri)
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
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}
      client = HTTP::Client.new(uri)
      client.before_request(&.headers.merge!(headers))

      begin
        client.get(uri.request_target, headers: headers) do |response|
          case response.status_code
          when 200
            File.open(dest_path, "wb") do |file|
              length_header = response.headers["Content-Length"]?
              total = length_header ? length_header.to_i64 : 0_i64
              downloaded = 0_i64
              bar_width = 40

              if stream = response.body_io
                buf = Bytes.new(16384)
                loop do
                  read_bytes = stream.read(buf)
                  break if read_bytes == 0
                  file.write(buf[0, read_bytes])
                  downloaded += read_bytes

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
            if HTTPClient.no_tty_progress_bar?
              puts "Download complete"
            else
              puts "\rDownload complete#{" " * 40}"
            end
          when 301, 302
            if loc = response.headers["Location"]?
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
