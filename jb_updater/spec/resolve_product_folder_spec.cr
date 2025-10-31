require "./spec_helper"
require "file_utils"
include JBUpdater

describe Utils do
  describe ".resolve_product_folder" do
    it "returns exact folder when full name is provided" do
      tmp = File.join(Dir.tempdir, "jb-test-#{Random::Secure.hex(4)}")
      base = ""

      {% if flag?(:darwin) %}
        base = File.join(tmp, "Library/Application Support/JetBrains")
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "WebStorm2025.2"))
      ENV["HOME"] = tmp

      begin
        result = Utils.resolve_product_folder("WebStorm2025.2")
        result.should eq "WebStorm2025.2"
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "returns latest matching folder for short product name" do
      tmp = File.join(Dir.tempdir, "jb-test-#{Random::Secure.hex(4)}")
      base = ""
      {% if flag?(:darwin) %}
        base = File.join(tmp, "Library/Application Support/JetBrains")
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "WebStorm2024.1"))
      FileUtils.mkdir_p(File.join(base, "WebStorm2025.2"))
      ENV["HOME"] = tmp

      begin
        latest = Utils.resolve_product_folder("WebStorm")
        latest.should eq "WebStorm2025.2"
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "raises if no matching folder found" do
      tmp = File.join(Dir.tempdir, "jb-test-#{Random::Secure.hex(4)}")
      base = ""
      {% if flag?(:darwin) %}
        base = File.join(tmp, "Library/Application Support/JetBrains")
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
      {% end %}

      FileUtils.mkdir_p(base)
      ENV["HOME"] = tmp

      begin
        expect_raises(Exception, /No config folder/) do
          Utils.resolve_product_folder("GhostIDE")
        end
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe ".expand_jetbrains_plugins_dir" do
    it "builds correct plugins path" do
      tmp = File.join(Dir.tempdir, "jb-home-#{Random::Secure.hex(4)}")
      base = ""
      {% if flag?(:darwin) %}
        base = File.join(tmp, "Library/Application Support/JetBrains")
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "RubyMine2025.2"))
      ENV["HOME"] = tmp

      begin
        path = Utils.expand_jetbrains_plugins_dir("RubyMine2025.2")
        {% if flag?(:darwin) %}
          path.should end_with "/Library/Application Support/JetBrains/RubyMine2025.2/plugins"
        {% elsif flag?(:linux) %}
          path.should end_with "/.local/share/JetBrains/RubyMine2025.2/plugins"
        {% elsif flag?(:win32) %}
          path.should end_with "\\JetBrains\\RubyMine2025.2\\plugins"
        {% end %}
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end
