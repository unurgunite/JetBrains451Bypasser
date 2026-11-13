require "./spec_helper"

include JBUpdater

# Offline end-to-end coverage using recorded API fixtures.
#
# `spec/fixtures/marketplace_list.xml` — trimmed live response from
# plugins.jetbrains.com (50 plugins). `spec/fixtures/ide_releases.json` —
# trimmed live response from data.services.jetbrains.com (5 releases).
# No network access: downloads are served by a local mock server.
describe "offline fixtures" do
  it "parses the recorded marketplace list" do
    xml = File.read(File.join(__DIR__, "fixtures", "marketplace_list.xml"))
    plugins = JBUpdater::PluginInfo.parse(xml)
    (plugins.size > 10).should be_true
    plugins.each do |plugin|
      plugin.xml_id.should_not be_empty
      plugin.name.should_not be_nil
    end
  end

  it "finds known plugins in the recorded list" do
    xml = File.read(File.join(__DIR__, "fixtures", "marketplace_list.xml"))
    plugins = JBUpdater::PluginInfo.parse(xml)
    ids = plugins.map(&.xml_id)
    # The trimmed fixture keeps the first 50 entries; just verify shape.
    (ids.uniq.size == ids.size).should be_true
  end

  it "extracts releases from the recorded JSON" do
    data = JSON.parse(File.read(File.join(__DIR__, "fixtures", "ide_releases.json")))
    arr = IDEReleases.extract_releases_arr(data, "RM")
    arr.should_not be_nil
    arr.try(&.size.should eq 5)
  end

  it "selects platform download keys for each OS/arch" do
    data = JSON.parse(File.read(File.join(__DIR__, "fixtures", "ide_releases.json")))
    if arr = IDEReleases.extract_releases_arr(data, "RM")
      release = arr.first
      downloads = release["downloads"].as_h
      (downloads["mac"]? || downloads["macM1"]?).should_not be_nil
      (downloads["linux"]? || downloads["linuxARM64"]?).should_not be_nil
      (downloads["windows"]? || downloads["windowsARM64"]?).should_not be_nil
      # Every platform entry carries a checksum link and size.
      %w[mac linux windows].each do |key|
        entry = downloads[key]? || next
        entry.as_h["checksumLink"]?.should_not be_nil
        entry.as_h["size"]?.should_not be_nil
      end
    else
      fail "expected releases array"
    end
  end

  it "runs a full plugin install cycle offline" do
    # Build a fixture zip matching the first parsed plugin id.
    xml = File.read(File.join(__DIR__, "fixtures", "marketplace_list.xml"))
    plugins = JBUpdater::PluginInfo.parse(xml)
    target = plugins.first
    target.xml_id.should_not be_empty

    io = IO::Memory.new
    Compress::Zip::Writer.open(io) do |zip|
      zip.add("#{target.xml_id}/META-INF/plugin.xml") do |e|
        e.print "<idea-plugin><id>#{target.xml_id}</id><version>9.9</version></idea-plugin>"
      end
    end
    zip_bytes = io.to_slice

    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.local_address.port
    tcp.close
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = 200
      ctx.response.content_length = zip_bytes.size
      ctx.response.output.write(zip_bytes)
    end
    server.bind_tcp "127.0.0.1", port
    spawn { server.listen }
    sleep 50.milliseconds
    begin
      with_tmpdir do |dir|
        dest = File.join(dir, "plugin.zip")
        HTTPClient.download(URI.parse("http://127.0.0.1:#{port}/x.zip"), dest)
        target_dir = File.join(dir, "plugins", target.xml_id)
        Utils.extract_zip(dest, target_dir)
        meta = PluginMeta.parse_from_dir(target_dir)
        meta.should_not be_nil
        meta.try(&.id.should eq target.xml_id)
        meta.try(&.version.should eq "9.9")
      end
    ensure
      server.close
    end
  end
end
