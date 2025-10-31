require "xml"
require "./utils"

module JBUpdater
  class PluginMeta
    getter id : String
    getter version : String
    getter since : String?
    getter until_build : String?
    getter path : String

    def initialize(
      *,
      id : String,
      version : String,
      since : String? = nil,
      until_build : String? = nil,
      path : String,
    )
      @id = id
      @version = version
      @since = since
      @until_build = until_build
      @path = path
    end

    # Scan a directory of plugins and return a map xmlId -> PluginMeta
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

    def self.parse_from_dir(dir : String) : PluginMeta?
      xml_path = File.join(dir, "META-INF", "plugin.xml")
      if File.exists?(xml_path)
        xml = File.read(xml_path)
        return parse_xml(xml, dir)
      end

      # check lib jars
      Dir.glob(File.join(dir, "lib", "*.jar")).each do |jar|
        if xml = read_text_from_jar(jar, "META-INF/plugin.xml")
          return parse_xml(xml, dir)
        end
      end

      nil
    end

    def self.parse_xml(xml : String, path : String) : PluginMeta?
      begin
        doc = XML.parse(xml)
        id_node = doc.xpath_node("//id") || doc.xpath_node("//name")
        version_node = doc.xpath_node("//version")
        idea_version = doc.xpath_node("//idea-version")
        since = idea_version.try &.["since-build"]? || idea_version.try &.["sinceBuild"]?
        until_build = idea_version.try &.["until-build"]? || idea_version.try &.["untilBuild"]?
        id = id_node.try &.content
        version = version_node.try &.content
        return nil unless id && version
        new(id: id.strip, version: version.strip, since: since.try &.strip, until_build: until_build.try &.strip, path: path)
      rescue ex : XML::Error
        nil
      end
    end

    # Uses unzip -p to read a text file inside JAR
    def self.read_text_from_jar(jar_path : String, inner_path : String) : String?
      out, status = Utils.run_cmd("unzip", "-p", jar_path, inner_path)
      status.success? ? out : nil
    rescue ex
      nil
    end
  end
end
