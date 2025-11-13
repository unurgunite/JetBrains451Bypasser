require "http/client"
require "uri"

module JBUpdater
  class HTTPClient
    USER_AGENT = "jb-updater/crystal/1.0 (+https://github.com/unurgunite)"

    # ----------------------------------------------------------------------
    # Perform a HEAD or GET and return the Response
    # ----------------------------------------------------------------------
    def self.head_or_get(url : String, method : Symbol = :get) : HTTP::Client::Response
      uri = URI.parse(url)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = HTTP::Client.new(uri)
      client.before_request { |req| req.headers.merge!(headers) }

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
      client.before_request { |req| req.headers.merge!(headers) }

      begin
        client.get(uri.request_target, headers: headers) do |response|
          case response.status_code
          when 200
            File.open(dest_path, "wb") do |f|
              # try to read expected length from header
              length_header = response.headers["Content-Length"]?
              total = length_header ? length_header.to_i64 : 0_i64
              downloaded = 0_i64
              bar_width = 40

              if stream = response.body_io
                buf = Bytes.new(16384)
                loop do
                  read_bytes = stream.read(buf)
                  break if read_bytes == 0
                  f.write(buf[0, read_bytes])
                  downloaded += read_bytes

                  if total > 0
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
            puts "\rDownload complete#{" " * 40}"
          when 301, 302
            if loc = response.headers["Location"]?
              next_uri = URI.parse(loc)
              unless next_uri.absolute?
                next_uri = URI.new(
                  scheme: uri.scheme,
                  host: uri.host,
                  port: uri.port, # keep same port
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
      return uri unless downloads_host && !downloads_host.empty?
      return uri unless uri.host =~ /^plugins\.jetbrains\.com$/i &&
                        uri.path.starts_with?("/files/")
      URI.new(scheme: "https", host: downloads_host,
        path: uri.path, query: uri.query)
    end
  end
end
