require "./spec_helper"
include JBUpdater

describe PluginMeta do
  it "parses valid plugin.xml" do
    xml = <<-XML
      <idea-plugin>
        <id>org.jetbrains.demo</id>
        <version>2025.1.0</version>
        <idea-version since-build="252.0" until-build="260.*"/>
      </idea-plugin>
    XML

    plugin = PluginMeta.parse_xml(xml, "/tmp/fake").not_nil!
    plugin.id.should eq "org.jetbrains.demo"
    plugin.version.should eq "2025.1.0"
    plugin.since.should eq "252.0"
    plugin.until_build.should eq "260.*"
  end

  it "returns nil for broken xml" do
    PluginMeta.parse_xml("<xml>", "/tmp").should be_nil
  end
end
