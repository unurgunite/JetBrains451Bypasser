require "http/client"
require "uri"

module JBUpdater
  class HTTPClient
    USER_AGENT = "jb-updater/crystal/1.0 (+https://github.com/unurgunite)"

    # Perform a HEAD or GET and return the Response
    def self.head_or_get(url : String, method : Symbol = :get) : HTTP::Client::Response
      uri = URI.parse(url)
      headers = HTTP::Headers{
        "User-Agent" => USER_AGENT,
      }

      client = HTTP::Client.new(uri)
      client.before_request do |req|
        req.headers.merge!(headers)
      end

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

    def self.download(uri : URI, dest_path : String) : Nil
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = HTTP::Client.new(uri)
      client.before_request { |req| req.headers.merge!(headers) }

      begin
        client.get(uri.request_target, headers: headers) do |response|
          case response.status_code
          when 200
            File.open(dest_path, "wb") do |f|
              # Crystal streams the body through the block; just copy as it comes
              IO.copy(response.body_io, f) if response.body_io
            end
          when 301, 302
            if loc = response.headers["Location"]?
              next_uri = URI.parse(loc)
              unless next_uri.absolute?
                next_uri = URI.new(
                  scheme: uri.scheme,
                  host: uri.host,
                  port: uri.port, # ← keep same port!
                  path: loc
                )
              end
              return download(next_uri, dest_path)
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

    def self.override_plugin_repo_host(uri : URI, downloads_host : String?) : URI
      return uri unless downloads_host && !downloads_host.empty?
      return uri unless uri.host =~ /^plugins\.jetbrains\.com$/i && uri.path.starts_with?("/files/")
      URI.new(scheme: "https", host: downloads_host, path: uri.path, query: uri.query)
    end
  end
end
