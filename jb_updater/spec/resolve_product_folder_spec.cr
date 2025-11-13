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
        ENV["HOME"] = tmp
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
        ENV["HOME"] = tmp
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
        FileUtils.mkdir_p(File.dirname(base)) # ensure C:\...AppData\Roaming exists
        ENV["APPDATA"] = File.join(tmp, "AppData", "Roaming")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "WebStorm2025.2"))

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
        ENV["HOME"] = tmp
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
        ENV["HOME"] = tmp
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
        FileUtils.mkdir_p(File.dirname(base))
        ENV["APPDATA"] = File.join(tmp, "AppData", "Roaming")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "WebStorm2024.1"))
      FileUtils.mkdir_p(File.join(base, "WebStorm2025.2"))

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
        ENV["HOME"] = tmp
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
        ENV["HOME"] = tmp
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
        FileUtils.mkdir_p(File.dirname(base))
        ENV["APPDATA"] = File.join(tmp, "AppData", "Roaming")
      {% end %}

      FileUtils.mkdir_p(base)

      begin
        expect_raises(Exception, /No config folder/) do
          Utils.resolve_product_folder("FooIDE")
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
        ENV["HOME"] = tmp
      {% elsif flag?(:linux) %}
        base = File.join(tmp, ".local/share/JetBrains")
        ENV["HOME"] = tmp
      {% elsif flag?(:win32) %}
        base = File.join(tmp, "AppData", "Roaming", "JetBrains")
        FileUtils.mkdir_p(File.dirname(base))
        ENV["APPDATA"] = File.join(tmp, "AppData", "Roaming")
      {% end %}

      FileUtils.mkdir_p(File.join(base, "RubyMine2025.2"))

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
