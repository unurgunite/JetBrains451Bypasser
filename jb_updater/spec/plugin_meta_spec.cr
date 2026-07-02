require "./spec_helper"
include JBUpdater

describe PluginMeta do
  describe ".parse_xml" do
    it "parses valid plugin.xml" do
      xml = <<-XML
        <idea-plugin>
          <id>org.jetbrains.demo</id>
          <version>2025.1.0</version>
          <idea-version since-build="252.0" until-build="260.*"/>
        </idea-plugin>
      XML

      if p = PluginMeta.parse_xml(xml, "/tmp/fake")
        p.id.should eq "org.jetbrains.demo"
        p.version.should eq "2025.1.0"
        p.since.should eq "252.0"
        p.until_build.should eq "260.*"
        p.path.should eq "/tmp/fake"
      else
        fail "expected plugin to be parsed"
      end
    end

    it "parses plugin.xml with display name" do
      xml = <<-XML
        <idea-plugin>
          <name>My Plugin</name>
          <id>com.example.my</id>
          <version>1.0</version>
        </idea-plugin>
      XML
      p = PluginMeta.parse_xml(xml, "/tmp/fake")
      p.should_not be_nil
      p.try(&.name).should eq "My Plugin"
    end

    it "falls back to name when id is missing" do
      xml = <<-XML
        <idea-plugin>
          <name>Fallback Plugin</name>
          <version>1.0</version>
        </idea-plugin>
      XML
      PluginMeta.parse_xml(xml, "/tmp/fake").should_not be_nil
    end

    it "returns nil for broken xml" do
      PluginMeta.parse_xml("<xml>", "/tmp").should be_nil
    end
  end

  describe ".scan_dir" do
    it "scans plugin directories and returns metadata map" do
      with_tmpdir do |dir|
        plugin_dir = File.join(dir, "test-plugin")
        Dir.mkdir(plugin_dir)
        meta_dir = File.join(plugin_dir, "META-INF")
        Dir.mkdir(meta_dir)
        File.write(File.join(meta_dir, "plugin.xml"), <<-XML)
          <idea-plugin>
            <id>com.example.scanned</id>
            <version>1.0</version>
          </idea-plugin>
        XML

        result = PluginMeta.scan_dir(dir)
        result.size.should eq 1
        result["com.example.scanned"].version.should eq "1.0"
      end
    end

    it "skips hidden directories" do
      with_tmpdir do |dir|
        hidden = File.join(dir, ".hidden")
        Dir.mkdir(hidden)

        result = PluginMeta.scan_dir(dir)
        result.should be_empty
      end
    end

    it "returns empty hash for empty directory" do
      with_tmpdir do |dir|
        PluginMeta.scan_dir(dir).should be_empty
      end
    end
  end

  describe ".parse_from_dir" do
    it "parses plugin.xml from META-INF directory" do
      with_tmpdir do |dir|
        meta_inf = File.join(dir, "META-INF")
        Dir.mkdir(meta_inf)
        File.write(File.join(meta_inf, "plugin.xml"), <<-XML)
          <idea-plugin>
            <id>com.example.fromdir</id>
            <version>2.0</version>
          </idea-plugin>
        XML

        p = PluginMeta.parse_from_dir(dir)
        p.should_not be_nil
        p.try(&.id).should eq "com.example.fromdir"
      end
    end

    it "returns nil when no plugin.xml found" do
      with_tmpdir do |dir|
        PluginMeta.parse_from_dir(dir).should be_nil
      end
    end
  end

  describe ".read_text_from_jar" do
    it "returns nil when jar does not exist" do
      PluginMeta.read_text_from_jar("/tmp/nonexistent.jar", "META-INF/plugin.xml").should be_nil
    end
  end
end
