require "spec"
require "../src/jb_updater"

module JBUpdater
  class HTTPClient
    def self.head_or_get(url, method = :get) : HTTP::Client::Response
      HTTP::Client::Response.new(200, "OK", HTTP::Headers.new, IO::Memory.new)
    end
  end
end
