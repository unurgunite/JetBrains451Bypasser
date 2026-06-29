require "json"
require "http/client"
require "xml"

module JBUpdater
  struct PluginInfo
    getter id : Int64
    getter xml_id : String
    getter name : String
    getter description : String
    getter icon : String?
    getter categories : Array(String)
    getter downloads : Int64
    getter rating : Float64
    getter author : String?
    getter tags : Array(String)
    getter vendor : String?
    getter preview : String?

    def initialize(
      @id : Int64,
      @xml_id : String,
      @name : String,
      @description : String,
      @icon : String? = nil,
      @categories : Array(String)? = nil,
      @downloads : Int64 = 0,
      @rating : Float64 = 0.0,
      @author : String? = nil,
      @tags : Array(String) = [] of String,
      @vendor : String? = nil,
      @preview : String? = nil,
    )
      @categories ||= [] of String
      @tags ||= [] of String
    end

 def self.parse(xml_str : String) : Array(PluginInfo)
    result = [] of PluginInfo

    # Clean malformed <ff> tags, then use fast XML parser
    cleaned = xml_str.gsub(/<ff>[^<]*<\/ff>/, "")
    begin
      doc = XML.parse(cleaned)
      doc.xpath_nodes("//idea-plugin").each do |plugin_node|
        next unless plugin_node

        xml_id = ""
        name = ""
        description = ""
        vendor = ""

        if id_node = plugin_node.xpath_node("id")
          xml_id = id_node.content
        end
        if name_node = plugin_node.xpath_node("name")
          name = name_node.content
        end
        if desc_node = plugin_node.xpath_node("description")
          description = desc_node.content
        end
        if vendor_node = plugin_node.xpath_node("vendor")
          vendor = vendor_node.content
        end

        downloads = 0_i64
        if dm = plugin_node["downloads"]?
          downloads = dm.to_i64 rescue 0_i64
        end

        categories = [] of String
        if tag_node = plugin_node.xpath_node("tags")
          tag_node.content.split(",").each do |tag|
            t = tag.strip
            categories << t unless t.empty? || categories.includes?(t)
          end
        end

        result << PluginInfo.new(
          id: 0_i64,
          xml_id: xml_id,
          name: name,
          description: description.strip.gsub(/\s+/, " "),
          categories: categories,
          downloads: downloads,
          vendor: vendor,
        )
      end
    rescue ex
      # fallback: return empty
    end

    result
  end

    def download_url : String
      "https://plugins.jetbrains.com/files/#{Utils.escape(xml_id)}/#{id}"
    end

    def download_install_url : String
      "https://plugins.jetbrains.com/plugin/download?pluginId=#{Utils.escape(xml_id)}"
    end

    def download_for_build_url(build : String) : String
      "https://plugins.jetbrains.com/pluginManager?action=download&id=#{Utils.escape(xml_id)}&build=#{Utils.escape(build)}"
    end

    def formatted_downloads : String
      if downloads >= 1_000_000
        "#{(downloads.to_f / 1_000_000).round(1)}M"
      elsif downloads >= 1_000
        "#{(downloads.to_f / 1_000).round(1)}K"
      else
        downloads.to_s
      end
    end

    def star_rating : String
      "⭐" * 5
    end
  end

  class PluginMarketplace
    @@cache = {} of String => Array(PluginInfo)
    def self.clear_cache
      @@cache.clear
    end

    def self.list_by_build(build : String) : Array(PluginInfo)
      cached = @@cache[build]?
      return cached if cached

      params = HTTP::Params{"build" => build}
      url = "https://plugins.jetbrains.com/plugins/list/?#{params}"
      xml_str = fetch_raw_with_retry(url)
      return [] of PluginInfo if xml_str.nil? || xml_str.empty?
      plugins = PluginInfo.parse(xml_str)
      @@cache[build] = plugins
      plugins
    end

    def self.cached_build : String?
      @@cache.keys.first?
    end

    def self.cached_plugin_count : Int32
      @@cache.values.sum(&.size)
    end

    def self.search(query : String, build : String = "RM-2025.2") : Array(PluginInfo)
      # Get all plugins for the build and filter
      plugins = list_by_build(build)

      if query.empty?
        plugins
      else
        query_lower = query.downcase
        plugins.select do |p|
          p.name.downcase.includes?(query_lower) ||
            p.description.downcase.includes?(query_lower) ||
            p.xml_id.downcase.includes?(query_lower)
        end
      end
    end

    def self.list_all(build : String = "RM-2025.2") : Array(PluginInfo)
      list_by_build(build)
    end

    def self.top_downloaded(build : String = "RM-2025.2", max_count = 100) : Array(PluginInfo)
      Log.info "PluginMarketplace: fetching top downloaded for build #{build}"
      plugins = list_by_build(build)
      sorted = plugins.sort_by { |p| -p.downloads }[0...max_count] || [] of PluginInfo
      Log.info "PluginMarketplace: top downloaded: #{sorted.size} plugins"
      sorted
    end

    def self.newest(build : String = "RM-2025.2", max_count = 100) : Array(PluginInfo)
      Log.info "PluginMarketplace: fetching newest for build #{build}"
      result = list_by_build(build)[0...max_count] || [] of PluginInfo
      Log.info "PluginMarketplace: newest: #{result.size} plugins"
      result
    end

    def self.by_category(category : String, build : String = "RM-2025.2") : Array(PluginInfo)
      plugins = list_by_build(build)
      cat_lower = category.downcase
      plugins.select do |p|
        p.categories.any? { |c| c.downcase == cat_lower }
      end
    end

    def self.by_id(xml_id : String) : PluginInfo?
      plugins = list_by_build("RM-2025.2")
      plugins.find { |p| p.xml_id == xml_id }
    end

    def self.categories : Array(String)
      [
        "All",
        "All Languages",
        "Web",
        "Language Pack",
        "Formatting",
        "Deployment",
        "Education",
        "Documentation",
        "Editor Support",
        "File Types",
        "Integration",
        "jQuery",
        "Live Templates",
        "Monitoring",
        "Naming",
        "Navigation",
        "Plugin Development",
        "Predefined scripts",
        "Programming Languages",
        "Tool-Win Integration",
        "Version Control",
        "XSLT/XPath",
      ]
    end

    private def self.fetch_raw_with_retry(url : String, max_retries : Int32 = 3) : String?
      max_retries.times do |attempt|
        begin
          return fetch_raw(url)
        rescue ex : IO::Error
          Log.warn "Plugin marketplace request failed (attempt #{attempt + 1}/#{max_retries}): #{ex.message}"
          sleep((attempt + 1).seconds)
        rescue ex : RuntimeError
          if ex.message.try(&.starts_with?("HTTP 429"))
            Log.warn "Rate limited by plugin marketplace (attempt #{attempt + 1}/#{max_retries}), retrying..."
            sleep((5 * (attempt + 1)).seconds)
          else
            raise ex
          end
        end
      end
      raise "API request failed after #{max_retries} retries"
    end

    private def self.fetch_raw(url : String) : String?
      Log.info "Fetching plugin list: #{url}"

      headers = HTTP::Headers{
        "User-Agent" => HTTPClient::USER_AGENT,
        "Accept" => "application/xml, text/xml, */*",
      }
      client = HTTP::Client.new(URI.parse(url))
      client.read_timeout = 30.seconds
      client.connect_timeout = 15.seconds
      client.before_request(&.headers.merge!(headers))

      begin
        response = client.get(url)
        Log.info "Plugin marketplace responded with HTTP #{response.status_code}"

        case response.status_code
        when 200
          body = response.body.to_s
          Log.info "Received #{body.size} bytes from plugin marketplace"
          body
        when 301, 302
          loc = response.headers["Location"]?
          Log.info "Redirect to: #{loc}"
          if loc
            loc_uri = URI.parse(loc)
            full_url = loc_uri.absolute? ? loc_uri.to_s : "#{url.split('?').first}?#{loc.split('?').last}"
            return fetch_raw(full_url)
          end
          raise "redirect without Location header"
        when 404
          Log.warn "Plugin list not found (404) for #{url}"
          return ""
        when 429
          Log.warn "Rate limited (429) for #{url}"
          raise "HTTP 429"
        else
          Log.warn "Unexpected HTTP #{response.status_code} for #{url}"
          raise "HTTP #{response.status_code}"
        end
      ensure
        client.close
      end
    end
  end
end
