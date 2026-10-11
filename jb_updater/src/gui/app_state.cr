require "uing"

module App
  @@log : UIng::MultilineEntry?
  @@overall_progress : UIng::ProgressBar?
  @@plugin_progress : UIng::ProgressBar?
  @@buttons : Array(UIng::Button) = [] of UIng::Button
  @@busy : Bool = false
  @@shutting_down : Bool = false

  # Browse tab state
  @@browse_plugins : Array(JBUpdater::PluginInfo) = [] of JBUpdater::PluginInfo
  @@browse_table_model : UIng::Table::Model? = nil
  @@browse_handler : UIng::Table::Model::Handler? = nil
  @@selected_xml_id : String? = nil
  @@search_id : Int64 = 0
  @@detected_products : Array(JBUpdater::DetectedProduct)? = nil
  @@installed_plugins : Hash(String, JBUpdater::PluginMeta)? = nil
  @@installed_plugins_arr : Array(JBUpdater::PluginMeta) = [] of JBUpdater::PluginMeta
  @@installed_table : UIng::Table? = nil
  @@installed_model : UIng::Table::Model? = nil
  @@ide_releases : Array(JBUpdater::IDERelease) = [] of JBUpdater::IDERelease
  @@ide_selected_row : Int32 = -1
  @@ide_release_table : UIng::Table? = nil
  @@ide_release_model : UIng::Table::Model? = nil

  # Background operation state
  @@op_status : String = ""
  @@op_done : Bool = false
  @@op_mutex : Mutex = Mutex.new
  @@log_buffer : Array(String) = [] of String
  @@log_buffer_mutex : Mutex = Mutex.new

  # Status bar label (bottom of the window).
  @@status_label : UIng::Label? = nil

  # Two-step uninstall confirmation state.
  @@pending_uninstall : String? = nil
  @@pending_uninstall_at : Time::Instant = Time.instant

  def self.status_label : UIng::Label
    @@status_label || raise "status label not initialized"
  end

  def self.status_label=(label : UIng::Label)
    @@status_label = label
  end

  @@ide_badge : UIng::Label? = nil

  def self.ide_badge : UIng::Label?
    @@ide_badge
  end

  def self.ide_badge=(label : UIng::Label)
    @@ide_badge = label
  end

  # Arms a two-step uninstall confirmation for a plugin ID.
  def self.arm_uninstall(id : String)
    @@pending_uninstall = id
    @@pending_uninstall_at = Time.instant
  end

  # Consumes the confirmation if it matches and is still recent.
  def self.confirm_uninstall?(id : String) : Bool
    armed = @@pending_uninstall == id
    recent = @@pending_uninstall_at.elapsed < 10.seconds
    @@pending_uninstall = nil
    armed && recent
  end

  def self.cancel_uninstall
    @@pending_uninstall = nil
  end

  # Download progress (set from background thread, read from UI timer)
  @@download_progress : Int32 = 0
  @@download_total : Int64 = 0_i64
  @@download_progress_mutex : Mutex = Mutex.new

  # Drains accumulated log messages for display on the UI thread.
  def self.drain_log_buffer : Array(String)
    @@log_buffer_mutex.synchronize do
      buf = @@log_buffer.dup
      @@log_buffer.clear
      buf
    end
  end

  # Appends a message to the thread-safe log buffer.
  def self.push_log(msg : String)
    @@log_buffer_mutex.synchronize do
      @@log_buffer << msg
    end
  end

  # Records download progress from a background thread.
  def self.update_progress(downloaded : Int64, total : Int64)
    @@download_progress_mutex.synchronize do
      @@download_progress = total > 0 ? ((downloaded.to_f / total) * 100).to_i : 0
      @@download_total = total
    end
  end

  # macOS Sonoma bug: setEditable:NO prevents NSTextStorage text changes.
  # Workaround: temporarily enable editing, set text, disable editing.
  def self.safe_set_text(entry : UIng::MultilineEntry, text : String)
    entry.read_only = false
    entry.text = text
    entry.read_only = true
  end

  # Reads the current download progress percentage.
  def self.read_progress : Int32
    @@download_progress_mutex.synchronize { @@download_progress }
  end

  def self.op_status : String
    @@op_status
  end

  def self.op_status=(status : String)
    @@op_status = status
  end

  def self.op_done : Bool
    @@op_done
  end

  def self.op_done=(done : Bool)
    @@op_done = done
  end

  def self.op_mutex : Mutex
    @@op_mutex
  end

  def self.browse_plugins
    @@browse_plugins
  end

  def self.browse_plugins=(plugins : Array(JBUpdater::PluginInfo))
    @@browse_plugins = plugins
  end

  def self.browse_table_model
    @@browse_table_model
  end

  def self.browse_table_model=(model : UIng::Table::Model?)
    @@browse_table_model = model
  end

  def self.browse_handler
    @@browse_handler
  end

  def self.browse_handler=(handler : UIng::Table::Model::Handler?)
    @@browse_handler = handler
  end

  def self.selected_xml_id
    @@selected_xml_id
  end

  def self.selected_xml_id=(id : String?)
    @@selected_xml_id = id
  end

  def self.search_id
    @@search_id
  end

  def self.search_id=(id : Int64)
    @@search_id = id
  end

  def self.detected_products
    @@detected_products
  end

  def self.detected_products=(products : Array(JBUpdater::DetectedProduct)?)
    @@detected_products = products
  end

  def self.installed_plugins
    @@installed_plugins
  end

  def self.installed_plugins=(plugins : Hash(String, JBUpdater::PluginMeta)?)
    @@installed_plugins = plugins
    refresh_installed_list
  end

  def self.installed_plugins_arr
    @@installed_plugins_arr
  end

  def self.refresh_installed_list
    if hash = @@installed_plugins
      @@installed_plugins_arr = hash.values.sort_by!(&.id)
    else
      @@installed_plugins_arr = [] of JBUpdater::PluginMeta
    end
  end

  def self.installed_table
    @@installed_table
  end

  def self.installed_table=(table : UIng::Table?)
    @@installed_table = table
  end

  def self.installed_model
    @@installed_model
  end

  def self.installed_model=(model : UIng::Table::Model?)
    @@installed_model = model
  end

  def self.ide_releases
    @@ide_releases
  end

  def self.ide_releases=(releases : Array(JBUpdater::IDERelease))
    @@ide_releases = releases
  end

  def self.ide_selected_row
    @@ide_selected_row
  end

  def self.ide_selected_row=(row : Int32)
    @@ide_selected_row = row
  end

  def self.ide_release_table
    @@ide_release_table
  end

  def self.ide_release_table=(table : UIng::Table?)
    @@ide_release_table = table
  end

  def self.ide_release_model
    @@ide_release_model
  end

  def self.ide_release_model=(model : UIng::Table::Model?)
    @@ide_release_model = model
  end

  def self.browse_detail
    @@browse_detail
  end

  def self.browse_detail=(entry : UIng::MultilineEntry?)
    @@browse_detail = entry
  end

  # Registers the log, progress bars, and tracked buttons for global access.
  def self.set_widgets(
    log : UIng::MultilineEntry,
    overall : UIng::ProgressBar,
    plugin : UIng::ProgressBar,
    buttons : Array(UIng::Button),
  )
    @@log = log
    @@overall_progress = overall
    @@plugin_progress = plugin
    @@buttons = buttons
  end

  def self.log : UIng::MultilineEntry
    @@log || raise "log not initialized"
  end

  def self.overall_progress : UIng::ProgressBar
    @@overall_progress || raise "overall_progress not initialized"
  end

  def self.plugin_progress : UIng::ProgressBar
    @@plugin_progress || raise "plugin_progress not initialized"
  end

  def self.busy? : Bool
    @@busy
  end

  def self.shutting_down? : Bool
    @@shutting_down
  end

  def self.mark_shutting_down
    @@shutting_down = true
  end

  # Forces the UI out of busy state and enables all tracked buttons.
  # Must be called from the UI thread.
  def self.debug_reenable
    return if @@shutting_down

    if @@log
      App.log.append("[GUI] debug_reenable(): forcing not busy and enabling buttons\n") rescue nil
    end

    @@busy = false
    @@buttons.each &.enable
  end

  # Enables or disables all tracked buttons and resets progress bars.
  # Must be called from the UI thread.
  def self.busy=(busy : Bool)
    return if @@shutting_down

    @@busy = busy

    if @@log
      begin
        App.log.append("[GUI] set_busy(#{busy}) for #{@@buttons.size} buttons\n")
      rescue
      end
    end

    enabled = !busy
    @@buttons.each do |btn|
      if enabled
        btn.enable
      else
        btn.disable
      end
    end

    if busy
      App.overall_progress.value = 0
      App.plugin_progress.value = 0
    else
      App.overall_progress.value = 100
      App.plugin_progress.value = 100
    end
  end
end
