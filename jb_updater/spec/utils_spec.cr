require "./spec_helper"
require "compress/zip"
include JBUpdater

describe Utils do
  describe ".safe" do
    it "replaces forbidden characters with underscores" do
      Utils.safe("a/b:c*?.zip").should eq "a_b_c__.zip"
    end
  end

  describe ".parse_build_string" do
    it "parses numeric build" do
      Utils.parse_build_string("2024.1.2").should eq [2024.0, 1.0, 2.0]
    end

    it "accepts wildcards" do
      Utils.parse_build_string("2024.1.*").should eq [2024.0, 1.0, Float64::INFINITY]
    end
  end

  describe ".build_in_range?" do
    it "returns true when build is between since/until" do
      Utils.build_in_range?("2024.1.2", "2024.0.0", "2024.2.0").should be_true
    end

    it "returns false when build is below since" do
      Utils.build_in_range?("2023.1.0", "2024.0.0", "2024.3.0").should be_false
    end
  end

  describe ".product_code" do
    it "maps known product names" do
      Utils.product_code("RubyMine2025.2").should eq "RM"
      Utils.product_code("WebStorm2025.1").should eq "WS"
      Utils.product_code("PyCharm2024.3").should eq "PY"
      Utils.product_code("CLion2025.1").should eq "CL"
      Utils.product_code("GoLand2025.2").should eq "GO"
      Utils.product_code("IntelliJ IDEA 2025.2").should eq "IU"
      Utils.product_code("PhpStorm2025.1").should eq "PS"
      Utils.product_code("Rider2025.1").should eq "RD"
    end

    it "matches lowercase names (e.g. from --ide-path)" do
      Utils.product_code("phpstorm").should eq "PS"
      Utils.product_code("webstorm").should eq "WS"
      Utils.product_code("intellij").should eq "IU"
    end

    it "maps short and alternate names" do
      Utils.product_code("ruby").should eq "RM"
      Utils.product_code("idea").should eq "IU"
      Utils.product_code("rm").should eq "RM"
      Utils.product_code("ws").should eq "WS"
      Utils.product_code("py").should eq "PY"
    end

    it "falls back to first two uppercase characters for unknown names" do
      Utils.product_code("MyCustomIDE").should eq "MY"
    end
  end

  describe ".version_numbers" do
    it "parses plain version suffix" do
      Utils.version_numbers("2025.2").should eq [2025.0, 2.0, 0.0]
    end

    it "does not raise on backup suffix" do
      Utils.version_numbers("2025.2-backup").should eq [2025.0, 2.0, 0.0]
    end

    it "does not raise on alpha fragment" do
      Utils.version_numbers("2025.2-eap").should eq [2025.0, 2.0, 0.0]
    end

    it "parses full three-part version" do
      Utils.version_numbers("2025.2.1").should eq [2025.0, 2.0, 1.0]
    end
  end

  describe ".backup_folder?" do
    it "detects .bak timestamps" do
      Utils.backup_folder?("WebStorm2025.2.bak.1700000000").should be_true
    end

    it "detects -backup suffix" do
      Utils.backup_folder?("WebStorm2025.2-backup").should be_true
    end

    it "accepts regular folders" do
      Utils.backup_folder?("WebStorm2025.2").should be_false
    end
  end

  describe ".read_zip_file" do
    it "reads a deflated entry from a zip without Compress::Zip parsing" do
      with_tmpdir do |dir|
        zip_path = File.join(dir, "archive.zip")
        File.open(zip_path, "w") do |io|
          Compress::Zip::Writer.open(io) do |zip|
            zip.add("plugin/META-INF/plugin.xml") { |e| e.print "<idea-plugin><id>org.test</id></idea-plugin>" }
          end
        end

        content = Utils.read_zip_file(zip_path, "plugin/META-INF/plugin.xml")
        content.should_not be_nil
        content.try(&.should contain "org.test")
      end
    end

    it "returns nil for a missing entry" do
      with_tmpdir do |dir|
        zip_path = File.join(dir, "archive.zip")
        File.open(zip_path, "w") do |io|
          Compress::Zip::Writer.open(io) do |zip|
            zip.add("plugin/file.txt") { |e| e.print "x" }
          end
        end

        Utils.read_zip_file(zip_path, "no/such.xml").should be_nil
      end
    end

    it "returns nil when the zip file does not exist" do
      Utils.read_zip_file("/tmp/does-not-exist.zip", "plugin.xml").should be_nil
    end
  end

  describe ".extract_zip" do
    it "extracts a single-root archive into the destination" do
      with_tmpdir do |dir|
        zip_path = File.join(dir, "archive.zip")
        File.open(zip_path, "w") do |io|
          Compress::Zip::Writer.open(io) do |zip|
            zip.add("plugin1/lib/a.jar") { |e| e.print "jar-bytes" }
          end
        end

        dest = File.join(dir, "dest")
        Utils.extract_zip(zip_path, dest)

        File.exists?(File.join(dest, "lib", "a.jar")).should be_true
        File.read(File.join(dest, "lib", "a.jar")).should eq "jar-bytes"
      end
    end
  end
end
