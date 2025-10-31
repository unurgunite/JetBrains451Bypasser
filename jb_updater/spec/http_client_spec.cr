require "./spec_helper"
include JBUpdater

describe HTTPClient do
  it "follows redirects recursively" do
    # Ask OS for an ephemeral free port
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.local_address.port
    tcp.close

    server = HTTP::Server.new do |ctx|
      if ctx.request.path == "/redirect"
        ctx.response.status_code = 302
        ctx.response.headers["Location"] = "/final"
      else
        ctx.response.status_code = 200
        ctx.response.print "ok!"
      end
    end

    address = server.bind_tcp "127.0.0.1", port
    spawn { server.listen }

    # sleep a small, non‑deprecated time span to let it bind
    sleep 50.milliseconds

    uri = URI.parse("http://127.0.0.1:#{port}/redirect")
    tmp = File.tempfile("download_test")
    begin
      HTTPClient.download(uri, tmp.path)
      File.read(tmp.path).should eq "ok!"
    ensure
      tmp.delete
      server.close
    end
  end

  it "overrides plugin host correctly" do
    uri = URI.parse("https://plugins.jetbrains.com/files/1234/yaml.zip")
    new_uri = HTTPClient.override_plugin_repo_host(uri, "cdn.jetbrains.io")
    new_uri.host.should eq "cdn.jetbrains.io"
    new_uri.path.should eq "/files/1234/yaml.zip"
  end
end
