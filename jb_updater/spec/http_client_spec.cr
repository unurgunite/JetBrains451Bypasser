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

    server.bind_tcp "127.0.0.1", port
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

  it "overrides IDE host correctly" do
    uri = URI.parse("https://download.jetbrains.com/ruby/RM-252.0.dmg")
    new_uri = HTTPClient.override_ide_repo_host(uri, "custom-cdn.example.com")
    new_uri.host.should eq "custom-cdn.example.com"
  end

  describe ".no_tty_progress_bar" do
    it "defaults to false" do
      HTTPClient.no_tty_progress_bar?.should be_false
    end

    it "can be set and read back" do
      HTTPClient.no_tty_progress_bar = true
      HTTPClient.no_tty_progress_bar?.should be_true
      HTTPClient.no_tty_progress_bar = false
    end
  end

  describe ".override_plugin_repo_host" do
    it "returns original URI when downloads_host is nil" do
      uri = URI.parse("https://plugins.jetbrains.com/files/test.zip")
      HTTPClient.override_plugin_repo_host(uri, nil).should be uri
    end

    it "returns original URI when host doesn't match" do
      uri = URI.parse("https://other.host.com/files/test.zip")
      new_uri = HTTPClient.override_plugin_repo_host(uri, "cdn.example.com")
      new_uri.should be uri
    end
  end
end
