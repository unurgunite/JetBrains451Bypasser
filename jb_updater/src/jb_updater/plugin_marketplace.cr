require "json"
require "http/client"
require "xml"

module JBUpdater
  # Strips HTML tags and decodes common HTML entities from a string.
  #
  # @param html [String] Raw HTML input
  # @return [String] Plain text with tags removed and entities decoded
  def self.html_strip(html : String) : String
    text = html.gsub(/<[^>]*>/, " ")
      .gsub("&amp;", "&")
      .gsub("&lt;", "<")
      .gsub("&gt;", ">")
      .gsub("&quot;", "\"")
      .gsub("&#39;", "'")
      .gsub(/&#(\d+);/) { $1.to_i.chr rescue "?" }
    text.gsub(/\s+/, " ").strip
  end

  # Metadata for a plugin listed on the JetBrains Marketplace.
  struct PluginInfo
    # Numeric ID on the marketplace.
    getter id : Int64
    # XML identifier (e.g. `"org.intellij.plugins.yaml"`).
    getter xml_id : String
    # Display name.
    getter name : String
    # Plugin description (raw HTML).
    getter description : String
    # URL to the plugin icon, or `nil`.
    getter icon : String?
    # Category tags assigned to the plugin.
    getter categories : Array(String)
    # Total download count.
    getter downloads : Int64
    # Average star rating.
    getter rating : Float64
    # Author name, or `nil`.
    getter author : String?
    # Arbitrary tag strings.
    getter tags : Array(String)
    # Vendor name, or `nil`.
    getter vendor : String?
    # Preview image URL, or `nil`.
    getter preview : String?
    # Warning note about compatibility with the selected IDE build, or `nil`.
    #
    # Set when a plugin is only found through an older-build fallback
    # (e.g. DocScribe declares support only up to `261.*` but is shown
    # for a `262` IDE). It may still work — author just hasn't widened
    # the declared range — so it is a soft warning, not a hard block.
    getter compat_note : String?

    # @param id [Int64] Marketplace numeric ID
    # @param xml_id [String] XML identifier
    # @param name [String] Display name
    # @param description [String] HTML description
    # @param icon [String?] Icon URL
    # @param categories [Array(String)?] Category list
    # @param downloads [Int64] Download count
    # @param rating [Float64] Star rating
    # @param author [String?] Author name
    # @param tags [Array(String)] Tag list
    # @param vendor [String?] Vendor name
    # @param preview [String?] Preview image URL
    # @param compat_note [String?] Compatibility warning note
    def initialize(
      @id : Int64,
      @xml_id : String,
      @name : String,
      @description : String,
      @icon : String? = nil,
      @categories : Array(String) = [] of String,
      @downloads : Int64 = 0,
      @rating : Float64 = 0.0,
      @author : String? = nil,
      @tags : Array(String) = [] of String,
      @vendor : String? = nil,
      @preview : String? = nil,
      @compat_note : String? = nil,
    )
    end

    # Returns a copy of this plugin with a compatibility note attached.
    #
    # `PluginInfo` is a value struct; the note is only known after the
    # plugin has been fetched (e.g. as an older-build fallback hit).
    #
    # @param note [String] Warning text (e.g. `"Declared only up to 261.*"`)
    # @return [PluginInfo] Copy with `compat_note` set
    def with_compat_note(note : String) : PluginInfo
      PluginInfo.new(
        id, xml_id, name, description, icon, categories, downloads, rating,
        author, tags, vendor, preview, note
      )
    end

    # Parses the JetBrains Marketplace XML response into an array of `PluginInfo`.
    #
    # Strips malformed `<ff>` tags before parsing.
    #
    # @param xml_str [String] Raw XML from the marketplace API
    # @return [Array(PluginInfo)] Parsed plugins (empty on error)
    def self.parse(xml_str : String) : Array(PluginInfo)
      result = [] of PluginInfo

      cleaned = xml_str.gsub(/<ff>[^<]*<\/ff>/, "")
      begin
        doc = XML.parse(cleaned)
        doc.xpath_nodes("//idea-plugin").each do |plugin_node|
          if plugin = parse_plugin_node(plugin_node)
            result << plugin
          end
        end
      rescue
      end

      result
    end

    # Extracts a single `PluginInfo` from an `<idea-plugin>` XML node.
    #
    # Missing optional fields (rating, downloads, tags) default safely.
    #
    # @param plugin_node [XML::Node] The `<idea-plugin>` element
    # @return [PluginInfo?] Parsed plugin, or `nil` for empty nodes
    private def self.parse_plugin_node(plugin_node : XML::Node) : PluginInfo?
      xml_id = node_text(plugin_node, "id")
      return if xml_id.empty?

      description = node_text(plugin_node, "description")
      downloads = 0_i64
      if dm = plugin_node["downloads"]?
        downloads = dm.to_i64 rescue 0_i64
      end
      rating = node_text(plugin_node, "rating").to_f rescue 0.0

      categories = [] of String
      if tag_node = plugin_node.xpath_node("tags")
        tag_node.content.split(",").each do |tag|
          t = tag.strip
          categories << t unless t.empty? || categories.includes?(t)
        end
      end

      PluginInfo.new(
        id: 0_i64,
        xml_id: xml_id,
        name: node_text(plugin_node, "name"),
        description: JBUpdater.html_strip(description).gsub(/\s+/, " ").strip,
        categories: categories,
        downloads: downloads,
        rating: rating,
        vendor: node_text(plugin_node, "vendor"),
      )
    end

    # Reads the text content of a direct child element, or `""`.
    #
    # @param node [XML::Node] Parent element
    # @param element [String] Child element name
    # @return [String] Element content or empty string
    private def self.node_text(node : XML::Node, element : String) : String
      node.xpath_node(element).try(&.content) || ""
    end

    # Returns the direct file download URL for this plugin.
    #
    # @return [String] e.g. `"https://plugins.jetbrains.com/files/yaml/12345"`
    def download_url : String
      "https://plugins.jetbrains.com/files/#{Utils.escape(xml_id)}/#{id}"
    end

    # Returns the generic install URL (always grabs the latest version).
    #
    # @return [String] e.g. `"https://plugins.jetbrains.com/plugin/download?pluginId=yaml"`
    def download_install_url : String
      "https://plugins.jetbrains.com/plugin/download?pluginId=#{Utils.escape(xml_id)}"
    end

    # Returns the marketplace URL for downloading this plugin for a specific IDE build.
    #
    # @param build [String] IDE build string (e.g. `"RM-252"`)
    # @return [String] Full URL with build parameter
    def download_for_build_url(build : String) : String
      "https://plugins.jetbrains.com/pluginManager?action=download&id=#{Utils.escape(xml_id)}&build=#{Utils.escape(build)}"
    end

    # Formats the download count with K/M suffixes.
    #
    # @return [String] e.g. `"1.2M"` or `"450K"` or `"123"`
    def formatted_downloads : String
      if downloads >= 1_000_000
        "#{(downloads.to_f / 1_000_000).round(1)}M"
      elsif downloads >= 1_000
        "#{(downloads.to_f / 1_000).round(1)}K"
      else
        downloads.to_s
      end
    end

    # Renders the plugin's average rating as filled/empty stars.
    #
    # Returns an em-dash for unrated plugins.
    #
    # @return [String] e.g. `"★★★★☆"` or `"—"`
    def star_rating : String
      return "—" if rating <= 0.0
      filled = rating.round.to_i.clamp(0, 5)
      "★" * filled + "☆" * (5 - filled)
    end
  end

  # Client for the JetBrains Plugin Marketplace API.
  #
  # Provides methods to list, search, and download plugins from
  # `plugins.jetbrains.com`. Results are cached in memory by
  # build string to avoid redundant requests.
  class PluginMarketplace
    @@cache = {} of String => Array(PluginInfo)
    @@cache_mutex = Mutex.new

    # Clears the in-memory plugin list cache.
    def self.clear_cache
      @@cache_mutex.synchronize { @@cache.clear }
    end

    # Fetches (or returns cached) plugin list for a given IDE build.
    #
    # HTTPS GET to `plugins.jetbrains.com/plugins/list/?build=...`,
    # parsed via `PluginInfo.parse`.
    #
    # @param build [String] IDE build string
    # @return [Array(PluginInfo)] List of available plugins
    def self.list_by_build(build : String) : Array(PluginInfo)
      cached = @@cache_mutex.synchronize { @@cache[build]? }
      return cached if cached

      params = HTTP::Params{"build" => build}
      url = "https://plugins.jetbrains.com/plugins/list/?#{params}"
      xml_str = fetch_raw_with_retry(url)
      return [] of PluginInfo if xml_str.nil? || xml_str.empty?
      plugins = PluginInfo.parse(xml_str)
      @@cache_mutex.synchronize { @@cache[build] = plugins }
      plugins
    end

    # Returns the first cached build key, or `nil`.
    #
    # @return [String?]
    def self.cached_build : String?
      @@cache.keys.first?
    end

    # Returns the total number of cached plugins across all builds.
    #
    # @return [Int32]
    def self.cached_plugin_count : Int32
      @@cache.values.sum(&.size)
    end

    # Filters the plugin list by a search query.
    #
    # Matches against name, description, and XML ID (case-insensitive).
    #
    # @param query [String] Search text
    # @param build [String] IDE build (default `"RM-2025.2"`)
    # @return [Array(PluginInfo)] Matching plugins
    def self.search(query : String, build : String = "RM-2025.2") : Array(PluginInfo)
      plugins = list_by_build(build)

      if query.empty?
        plugins
      else
        query_lower = query.downcase
        results = plugins.select do |plugin|
          plugin.name.downcase.includes?(query_lower) ||
            plugin.xml_id.downcase.includes?(query_lower)
        end

        # The plugin list API only returns plugins explicitly compatible
        # with the requested build. Some plugins declare a narrow range
        # (e.g. DocScribe: `261.*`) yet still work on newer IDEs. Fall
        # back through older builds of the same product so they show up
        # in search results. Plugins found this way are flagged with a
        # compatibility note (soft warning — they usually still work).
        if results.empty?
          Utils.previous_builds(build, limit: 4).each do |alt_build|
            alt = list_by_build(alt_build).select do |plugin|
              plugin.name.downcase.includes?(query_lower) ||
                plugin.xml_id.downcase.includes?(query_lower)
            end
            unless alt.empty?
              note = "Declared for build #{alt_build}, not for #{build} — may still work"
              results = alt.map(&.with_compat_note(note))
              break
            end
          end
        end

        results
      end
    end

    # Returns the full plugin list for a given build.
    #
    # @param build [String] IDE build (default `"RM-2025.2"`)
    # @return [Array(PluginInfo)]
    def self.list_all(build : String = "RM-2025.2") : Array(PluginInfo)
      list_by_build(build)
    end

    # Returns plugins sorted by download count, most popular first.
    #
    # @param build [String] IDE build (default `"RM-2025.2"`)
    # @param max_count [Int32] Maximum results (default 100)
    # @return [Array(PluginInfo)] Top downloaded plugins
    def self.top_downloaded(build : String = "RM-2025.2", max_count = 100) : Array(PluginInfo)
      Log.info "PluginMarketplace: fetching top downloaded for build #{build}"
      plugins = list_by_build(build)
      sorted = plugins.sort_by { |plugin| -plugin.downloads }[0...max_count] || [] of PluginInfo
      Log.info "PluginMarketplace: top downloaded: #{sorted.size} plugins"
      sorted
    end

    # Returns the most recently listed plugins.
    #
    # @param build [String] IDE build (default `"RM-2025.2"`)
    # @param max_count [Int32] Maximum results (default 100)
    # @return [Array(PluginInfo)] Newest plugins
    def self.newest(build : String = "RM-2025.2", max_count = 100) : Array(PluginInfo)
      Log.info "PluginMarketplace: fetching newest for build #{build}"
      result = list_by_build(build)[0...max_count] || [] of PluginInfo
      Log.info "PluginMarketplace: newest: #{result.size} plugins"
      result
    end

    # Filters plugins by a specific category tag.
    #
    # @param category [String] Category name (e.g. `"Web"`)
    # @param build [String] IDE build (default `"RM-2025.2"`)
    # @return [Array(PluginInfo)] Plugins in the given category
    def self.by_category(category : String, build : String = "RM-2025.2") : Array(PluginInfo)
      plugins = list_by_build(build)
      cat_lower = category.downcase
      plugins.select do |plugin|
        plugin.categories.any? { |cat| cat.downcase == cat_lower }
      end
    end

    # Finds a single plugin by its XML ID.
    #
    # @param xml_id [String] Plugin identifier
    # @return [PluginInfo?] Matching plugin or `nil`
    def self.by_id(xml_id : String) : PluginInfo?
      plugins = list_by_build("RM-2025.2")
      plugins.find { |plugin| plugin.xml_id == xml_id }
    end

    # Returns a hardcoded list of known marketplace categories.
    #
    # @return [Array(String)] 22 category names
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

    # Fetches the marketplace XML with automatic retry on transient errors.
    #
    # Retries up to `max_retries` times on `IO::Error` or HTTP 429
    # with exponential backoff.
    #
    # @param url [String] Marketplace API URL
    # @param max_retries [Int32] Maximum retry count (default 3)
    # @return [String?] Response body or `nil` on persistent failure
    private def self.fetch_raw_with_retry(url : String, max_retries : Int32 = 3) : String?
      max_retries.times do |attempt|
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
      raise "API request failed after #{max_retries} retries"
    end

    # Performs the raw HTTP GET to the marketplace, handling redirects and errors.
    #
    # @param url [String] Marketplace API URL
    # @return [String?] Response body or empty string on 404
    private def self.fetch_raw(url : String) : String?
      Log.info "Fetching plugin list: #{url}"

      headers = HTTP::Headers{
        "User-Agent" => HTTPClient::USER_AGENT,
        "Accept"     => "application/xml, text/xml, */*",
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
          ""
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
