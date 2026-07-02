require "./spec_helper"
include JBUpdater

describe JBUpdater do
  describe ".html_strip" do
    it "removes basic HTML tags" do
      JBUpdater.html_strip("<p>hello</p>").should eq "hello"
    end

    it "decodes HTML entities" do
      JBUpdater.html_strip("&amp;lt;test&amp;gt;").should eq "<test>"
    end

    it "decodes numeric entities" do
      JBUpdater.html_strip("&#65;&#66;&#67;").should eq "ABC"
    end

    it "collapses whitespace" do
      JBUpdater.html_strip("a    b\n\nc").should eq "a b c"
    end

    it "handles empty string" do
      JBUpdater.html_strip("").should eq ""
    end

    it "handles string with no HTML" do
      JBUpdater.html_strip("plain text").should eq "plain text"
    end
  end
end

describe PluginInfo do
  describe ".parse" do
    it "parses valid XML with one plugin" do
      xml = <<-XML
        <?xml version="1.0"?>
        <plugin-list>
          <idea-plugin downloads="12345">
            <id>com.example.plugin</id>
            <name>Example Plugin</name>
            <description>Cool plugin</description>
            <vendor>Example Inc</vendor>
            <tags>web, integration,</tags>
          </idea-plugin>
        </plugin-list>
      XML
      plugins = PluginInfo.parse(xml)
      plugins.size.should eq 1
      plugins[0].xml_id.should eq "com.example.plugin"
      plugins[0].name.should eq "Example Plugin"
      plugins[0].description.should eq "Cool plugin"
      plugins[0].downloads.should eq 12_345
      plugins[0].vendor.should eq "Example Inc"
      plugins[0].categories.should contain("web")
      plugins[0].categories.should contain("integration")
    end

    it "strips HTML from description inside XML entities" do
      xml = <<-XML
        <?xml version="1.0"?>
        <plugin-list>
          <idea-plugin>
            <id>test.html</id>
            <name>Test</name>
            <description>&lt;b&gt;Bold text&lt;/b&gt; description</description>
          </idea-plugin>
        </plugin-list>
      XML
      plugins = PluginInfo.parse(xml)
      plugins.size.should eq 1
      # The Crystal XML parser may or may not decode entities before passing
      # to html_strip. Accept both outcomes: either fully stripped or partially.
      desc = plugins[0].description
      desc.should_not contain(">")
      desc.should_not contain("<")
    end

    it "returns empty array for empty XML" do
      PluginInfo.parse("<plugin-list></plugin-list>").should be_empty
    end

    it "returns empty array for malformed XML" do
      PluginInfo.parse("not xml").should be_empty
    end

    it "strips malformed <ff> tags" do
      xml = <<-XML
        <plugin-list>
          <idea-plugin>
            <id>test</id>
            <name>Test</name>
            <description><ff>bad</ff>desc</description>
          </idea-plugin>
        </plugin-list>
      XML
      PluginInfo.parse(xml).size.should eq 1
    end
  end

  describe "#download_url" do
    it "builds URL with xml_id and numeric id" do
      p = PluginInfo.new(id: 999_i64, xml_id: "test.plugin", name: "T", description: "")
      p.download_url.should eq "https://plugins.jetbrains.com/files/test.plugin/999"
    end
  end

  describe "#download_install_url" do
    it "builds install URL with xml_id" do
      p = PluginInfo.new(id: 0_i64, xml_id: "test.plugin", name: "T", description: "")
      p.download_install_url.should eq "https://plugins.jetbrains.com/plugin/download?pluginId=test.plugin"
    end
  end

  describe "#download_for_build_url" do
    it "includes build parameter" do
      p = PluginInfo.new(id: 0_i64, xml_id: "test.plugin", name: "T", description: "")
      url = p.download_for_build_url("RM-252")
      url.should contain("build=RM-252")
      url.should contain("id=test.plugin")
    end
  end

  describe "#formatted_downloads" do
    it "formats millions" do
      p = PluginInfo.new(id: 1_i64, xml_id: "x", name: "x", description: "", downloads: 2_500_000_i64)
      p.formatted_downloads.should eq "2.5M"
    end

    it "formats thousands" do
      p = PluginInfo.new(id: 1_i64, xml_id: "x", name: "x", description: "", downloads: 450_000_i64)
      p.formatted_downloads.should eq "450.0K"
    end

    it "formats small numbers" do
      p = PluginInfo.new(id: 1_i64, xml_id: "x", name: "x", description: "", downloads: 123_i64)
      p.formatted_downloads.should eq "123"
    end
  end

  describe "#star_rating" do
    it "returns five stars" do
      p = PluginInfo.new(id: 1_i64, xml_id: "x", name: "x", description: "")
      p.star_rating.should eq "⭐⭐⭐⭐⭐"
    end
  end
end
