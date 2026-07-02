require "xml"
require "./utils"

module JBUpdater
  # Parsed metadata for an installed plugin.
  #
  # Reads and caches the essential fields from a plugin's
  # `META-INF/plugin.xml` — identifier, version, and IDE
  # build compatibility range.
  class PluginMeta
    # Plugin XML ID (e.g. `"com.intellij.database"`).
    getter id : String
    # Plugin display name (e.g. `"Database Tools and SQL"`).
    getter name : String?
    # Plugin version string (e.g. `"2025.1.0"`).
    getter version : String
    # Minimum compatible IDE build (e.g. `"252.0"`) or `nil`.
    getter since : String?
    # Maximum compatible IDE build (e.g. `"260.*"`) or `nil`.
    getter until_build : String?
    # Absolute path to the plugin directory.
    getter path : String

    # @param id [String] Plugin XML ID
    # @param version [String] Plugin version
    # @param since [String?] Minimum compatible build
    # @param until_build [String?] Maximum compatible build
    # @param path [String] Plugin directory path
    def initialize(
      *,
      id : String,
      name : String? = nil,
      version : String,
      since : String? = nil,
      until_build : String? = nil,
      path : String,
    )
      @id = id
      @name = name
      @version = version
      @since = since
      @until_build = until_build
      @path = path
    end

    # Scans a plugins directory and returns a map of `xml_id → PluginMeta`.
    #
    # Iterates over immediate subdirectories, skipping hidden entries,
    # and parses each one via `parse_from_dir`.
    #
    # @param root [String] Path to the plugins directory
    # @return [Hash(String, PluginMeta)] Plugin ID to metadata mapping
    def self.scan_dir(root : String) : Hash(String, PluginMeta)
      result = {} of String => PluginMeta
      Dir.each_child(root) do |entry|
        next if entry.starts_with?(".")
        path = File.join(root, entry)
        next unless File.directory?(path)
        if meta = parse_from_dir(path)
          result[meta.id] = meta
        end
      end
      result
    end

    # Parses a single plugin directory, looking for `META-INF/plugin.xml`.
    #
    # Checks the plugin directory directly first, then falls back to
    # searching inside JAR files under `lib/`.
    #
    # @param dir [String] Plugin directory path
    # @return [PluginMeta?] Parsed metadata or `nil`
    def self.parse_from_dir(dir : String) : PluginMeta?
      xml_path = File.join(dir, "META-INF", "plugin.xml")
      if File.exists?(xml_path)
        xml = File.read(xml_path)
        return parse_xml(xml, dir)
      end

      Dir.glob(File.join(dir, "lib", "*.jar")).each do |jar|
        if xml = read_text_from_jar(jar, "META-INF/plugin.xml")
          return parse_xml(xml, dir)
        end
      end

      nil
    end

    # Parses plugin metadata from raw XML content.
    #
    # Extracts `//id` (or `//name` as fallback), `//version`, and
    # `//idea-version` attributes (`since-build`, `until-build`).
    #
    # @param xml [String] XML content
    # @param path [String] Plugin directory path (stored in result)
    # @return [PluginMeta?] Parsed metadata or `nil` on error
    def self.parse_xml(xml : String, path : String) : PluginMeta?
      doc = XML.parse(xml)
      id_node = doc.xpath_node("//id") || doc.xpath_node("//name")
      name_node = doc.xpath_node("//name")
      version_node = doc.xpath_node("//version")
      idea_version = doc.xpath_node("//idea-version")
      since = idea_version.try &.["since-build"]? || idea_version.try &.["sinceBuild"]?
      until_build = idea_version.try &.["until-build"]? || idea_version.try &.["untilBuild"]?
      id = id_node.try &.content
      name = name_node.try &.content
      version = version_node.try &.content
      return nil unless id && version
      new(id: id.strip, name: name.try(&.strip), version: version.strip, since: since.try &.strip, until_build: until_build.try &.strip, path: path)
    rescue ex : XML::Error
      nil
    end

    # Reads a file from inside a JAR using `unzip -p`.
    def self.read_text_from_jar(jar_path : String, inner_path : String) : String?
      io = IO::Memory.new
      status = Process.run("unzip", {"-p", jar_path, inner_path}, output: io, error: :close)
      status.success? ? io.to_s : nil
    rescue
      nil
    end
  end
end
