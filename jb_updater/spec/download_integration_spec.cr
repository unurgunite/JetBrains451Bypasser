require "./spec_helper"

include JBUpdater

# Builds a minimal plugin zip in memory.
def build_test_zip : Bytes
  io = IO::Memory.new
  Compress::Zip::Writer.open(io) do |zip|
    zip.add("test-plugin/META-INF/plugin.xml") do |e|
      e.print "<idea-plugin><id>org.integration</id><version>1.0</version></idea-plugin>"
    end
    zip.add("test-plugin/lib/code.jar", &.print("jar-bytes"))
  end
  io.to_slice
end

# Starts a mock server serving *zip_bytes* at /plugin.zip (+ /redirect).
# Returns {server, port}. Caller must server.close in ensure.
def start_mock_server(zip_bytes : Bytes) : Tuple(HTTP::Server, Int32)
  tcp = TCPServer.new("127.0.0.1", 0)
  port = tcp.local_address.port
  tcp.close

  server = HTTP::Server.new do |ctx|
    case ctx.request.path
    when "/redirect"
      ctx.response.status_code = 302
      ctx.response.headers["Location"] = "/plugin.zip"
    when "/plugin.zip"
      if range = ctx.request.headers["Range"]?
        start_at = range.sub("bytes=", "").split("-").first.to_i64
        tail = zip_bytes[start_at..]
        ctx.response.status_code = 206
        ctx.response.content_length = tail.size
        ctx.response.output.write(tail)
      else
        ctx.response.status_code = 200
        ctx.response.content_length = zip_bytes.size
        ctx.response.output.write(zip_bytes)
      end
    else
      ctx.response.status_code = 404
      ctx.response.print "nope"
    end
  end

  server.bind_tcp "127.0.0.1", port
  spawn { server.listen }
  sleep 50.milliseconds
  {server, port}
end

# End-to-end download flows against a local mock HTTP server.
#
# Covers: happy-path download + atomic replace, redirect following,
# checksum verification (match + mismatch), resume via Range, and
# retry on transient 5xx. No external network access.
describe "download integration" do
  it "downloads a zip through a redirect and replaces atomically" do
    zip = build_test_zip
    server, port = start_mock_server(zip)
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        # Pre-create dest like File.tempfile does (Windows rename edge).
        File.write(dest, "stale")
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/redirect"), dest)
        File.exists?("#{dest}.part").should be_false
        (Utils.read_zip_file(dest, "test-plugin/META-INF/plugin.xml") || "").should contain "org.integration"
      end
    ensure
      server.close
    end
  end

  it "verifies SHA-256 when expected hash matches" do
    zip = build_test_zip
    digest = Digest::SHA256.new
    digest.update(zip)
    sha = digest.final.hexstring
    server, port = start_mock_server(zip)
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/plugin.zip"), dest, 0, sha)
        File.exists?(dest).should be_true
      end
    ensure
      server.close
    end
  end

  it "rejects download on SHA-256 mismatch and removes .part" do
    zip = build_test_zip
    server, port = start_mock_server(zip)
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        expect_raises(RuntimeError, /SHA-256 mismatch/) do
          HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/plugin.zip"), dest, 0, "0" * 64)
        end
        File.exists?(dest).should be_false
        File.exists?("#{dest}.part").should be_false
      end
    ensure
      server.close
    end
  end

  it "resumes a partial download via Range requests" do
    zip = build_test_zip
    server, port = start_mock_server(zip)
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        half = zip.size // 2
        File.write("#{dest}.part", zip[0, half])
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/plugin.zip"), dest)
        File.read(dest).should eq String.new(zip)
      end
    ensure
      server.close
    end
  end

  it "retries transient 5xx and succeeds" do
    zip = build_test_zip
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.local_address.port
    tcp.close
    count = 0
    server = HTTP::Server.new do |ctx|
      count += 1
      if count == 1
        ctx.response.status_code = 503
        ctx.response.print "try later"
      else
        ctx.response.status_code = 200
        ctx.response.content_length = zip.size
        ctx.response.output.write(zip)
      end
    end
    server.bind_tcp "127.0.0.1", port
    spawn { server.listen }
    sleep 50.milliseconds
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/flaky"), dest)
        File.exists?(dest).should be_true
        (count >= 2).should be_true
      end
    ensure
      server.close
    end
  end

  it "extracts a downloaded plugin zip end to end" do
    zip = build_test_zip
    server, port = start_mock_server(zip)
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "download.zip")
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/plugin.zip"), dest)
        target = File.join(dir, "plugins", "org.integration")
        Utils.extract_zip(dest, target)
        meta = PluginMeta.parse_from_dir(target)
        meta.should_not be_nil
        meta.try(&.id.should eq "org.integration")
      end
    ensure
      server.close
    end
  end
end
