require "json"

# Settings persistence helpers.
#
# Stores GUI field values as JSON under `~/.jb_updater_gui/config.json`.
module GuiSettings
  CONFIG_DIR  = File.expand_path(File.join(ENV["HOME"], ".jb_updater_gui"))
  CONFIG_FILE = File.join(CONFIG_DIR, "config.json")

  # Reads the saved config JSON, returning an empty hash on error.
  #
  # @return [Hash(String, String)] Saved config key-value pairs
  private struct SavedConfig
    include JSON::Serializable

    getter data : Hash(String, String)

    def initialize(@data = {} of String => String)
    end
  end

  # @return [Hash(String, String)] Saved config key-value pairs
  def self.load : Hash(String, String)
    return {} of String => String unless File.exists?(CONFIG_FILE)
    begin
      SavedConfig.from_json(File.read(CONFIG_FILE)).data
    rescue
      {} of String => String
    end
  end

  # Writes config hash to JSON file.
  #
  # @param hash [Hash(String, String)] Config key-value pairs
  def self.save(hash : Hash(String, String))
    Dir.mkdir_p(CONFIG_DIR) unless Dir.exists?(CONFIG_DIR)
    File.write(CONFIG_FILE, hash.to_json)
  end

  # Expands `~` in a path string.
  #
  # @param text [String?] Path string (may contain `~`)
  # @return [String?] Expanded path or nil
  def self.expand_tilde(text : String?) : String?
    return unless text
    return if text.empty?
    JBUpdater::Utils.expand_tilde(text)
  end
end
