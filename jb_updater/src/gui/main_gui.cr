require "../jb_updater"
require "../jb_updater/detect_products"
require "../jb_updater/plugin_marketplace"
require "../jb_updater/gui_actions"
require "file_utils"
require "json"
require "uing"

# Global access to log/progress widgets and browser state.
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

  # Background operation state
  @@op_status : String = ""
  @@op_done : Bool = false
  @@op_mutex : Mutex = Mutex.new
  @@log_buffer : Array(String) = [] of String
  @@log_buffer_mutex : Mutex = Mutex.new

  # Download progress (set from background thread, read from UI timer)
  @@download_progress : Int32 = 0
  @@download_total : Int64 = 0_i64
  @@download_progress_mutex : Mutex = Mutex.new

  # Drains accumulated log messages for display on the UI thread.
  def self.drain_log_buffer : Array(String)
    @@log_buffer_mutex.synchronize {
      buf = @@log_buffer.dup
      @@log_buffer.clear
      buf
    }
  end

  # Appends a message to the thread-safe log buffer.
  def self.push_log(msg : String)
    @@log_buffer_mutex.synchronize {
      @@log_buffer << msg
    }
  end

  # Records download progress from a background thread.
  def self.update_progress(downloaded : Int64, total : Int64)
    @@download_progress_mutex.synchronize {
      @@download_progress = total > 0 ? ((downloaded.to_f / total) * 100).to_i : 0
      @@download_total = total
    }
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

# Settings persistence helpers.
#
# Stores GUI field values as JSON under `~/.jb_updater_gui/config.json`.
module Settings
  CONFIG_DIR  = File.expand_path(File.join(ENV["HOME"], ".jb_updater_gui"))
  CONFIG_FILE = File.join(CONFIG_DIR, "config.json")
end

# Reads the saved config JSON, returning an empty hash on error.
#
# @return [Hash(String, String)] Saved config key-value pairs
private def load_config : Hash(String, String)
  return {} of String => String unless File.exists?(Settings::CONFIG_FILE)
  begin
    JSON.parse(File.read(Settings::CONFIG_FILE))
      .as_h
      .transform_values(&.as_s)
  rescue
    {} of String => String
  end
end

# Writes config hash to JSON file.
#
# @param hash [Hash(String, String)] Config key-value pairs
private def save_config(hash : Hash(String, String))
  Dir.mkdir_p(Settings::CONFIG_DIR) unless Dir.exists?(Settings::CONFIG_DIR)
  File.write(Settings::CONFIG_FILE, hash.to_json)
end

# Expands `~` in a path string.
#
# @param text [String?] Path string (may contain `~`)
# @return [String?] Expanded path or nil
private def expand_tilde(text : String?) : String?
  return nil unless text
  return nil if text.empty?
  JBUpdater::Utils.expand_tilde(text)
end

# Appends a formatted section header to the log console.
def new_run_header(action : String, args : Array(String))
  UIng.queue_main do
    App.log.append("\n")
    App.log.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    App.log.append("#{action} at #{Time.local}\n")
    App.log.append("Command: ./jb_updater #{args.join(" ")}\n")
    App.log.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
  end
end

# Builds a CLI argument array from the current GUI field values.
#
# @return [Array(String)] CLI arguments for `jb_updater`
private def arch_args(combo_arch : UIng::Combobox) : Array(String)
  case combo_arch.selected
  when 1 then ["--arch", "arm"]
  when 2 then ["--arch", "intel"]
  else        [] of String
  end
end

private def add_opt(args : Array(String), flag : String, value : String?)
  args.concat([flag, value]) if value && !value.empty?
end

private def build_args(
  e_plugins_dir : UIng::Entry,
  e_build : UIng::Entry,
  e_product : UIng::Entry,
  e_install_ids : UIng::Entry,
  combo_arch : UIng::Combobox,
  chk_dry : UIng::Checkbox,
  chk_list : UIng::Checkbox,
) : Array(String)
  args = [] of String

  add_opt(args, "--plugins-dir", expand_tilde(e_plugins_dir.text))
  add_opt(args, "--build", e_build.text)
  add_opt(args, "--product", e_product.text)
  add_opt(args, "--install-plugin", e_install_ids.text)

  args.concat(arch_args(combo_arch))

  args << "--dry-run" if chk_dry.checked?
  args << "--list" if chk_list.checked?
  args
end

# Locates the `jb_updater` executable (for subprocess invocation).
#
# Checks `Process.executable_path`, then CWD, then `JB_UPDATER` env var.
#
# @return [String] Path to the executable
private def jb_exe_path : String
  exe_path = Process.executable_path
  if exe_path.nil?
    App.log.append("[GUI] WARN: Process.executable_path is nil, trying CWD\n")
    return "./jb_updater" if File::Info.executable?("./jb_updater")
    return ENV["JB_UPDATER"]? || "jb_updater"
  end

  here = File.dirname(exe_path)
  cand = File.expand_path(File.join(here, "jb_updater"))

  return cand if File::Info.executable?(cand)
  return "./jb_updater" if File::Info.executable?("./jb_updater")
  ENV["JB_UPDATER"]? || "jb_updater"
end

# Runs `jb_updater` as a subprocess, streaming output to the log.
#
# @param args [Array(String)] CLI arguments
private def run_cli(args : Array(String)) : Nil
  return if App.busy?

  App.busy = true
  exe = jb_exe_path
  App.log.append("[CLI] jb_updater #{args.join(" ")}\n")

  Thread.new do
    begin
      output = IO::Memory.new
      status = Process.run(exe, args: args, output: output, error: output)

      result = output.to_s
      unless result.empty?
        result.each_line do |line|
          UIng.queue_main do
            next if App.shutting_down?
            App.log.append("[subprocess] #{line}\n")
          end
        end
      end

      UIng.queue_main do
        next if App.shutting_down?
        App.log.append("[CLI] exit code: #{status.exit_code}\n")
        App.plugin_progress.value = 100 if status.success?
        App.busy = false
        App.debug_reenable
      end
    rescue ex
      UIng.queue_main do
        next if App.shutting_down?
        App.log.append("[CLI] ERROR: #{ex.message}\n")
        App.busy = false
        App.debug_reenable
      end
    end
  end
end

# Enqueues a plugin for queue-based sequential installation from the Browse tab.
#
# Spawns a background thread that processes the queue one-by-one,
# updating the overall progress bar after each plugin.
#
# @param xml_id [String] Plugin XML identifier
# @param plugins_dir [String] Target plugins directory
# @param build [String] IDE build string
private def queue_install(xml_id : String, plugins_dir : String, build : String)
  JBUpdater::GUI::Actions.enqueue(xml_id, plugins_dir, build)

  App.log.append("[Browser] Queued: #{xml_id} (queue: #{JBUpdater::GUI::Actions.queue_size})\n")

  return if JBUpdater::GUI::Actions.processing?

  JBUpdater::GUI::Actions.processing = true
  JBUpdater::GUI::Actions.total = JBUpdater::GUI::Actions.queue_size
  App.busy = true
  App.plugin_progress.value = 0
  App.update_progress(0_i64, 1_i64)

  Thread.new do
    loop do
      item = JBUpdater::GUI::Actions.dequeue
      break if item.nil?

      xml_id, plugins_dir, build = item
      status_msg = ""

      remaining = JBUpdater::GUI::Actions.queue_size
      completed = JBUpdater::GUI::Actions.total - remaining
      App.push_log("[Browser] Installing (#{completed}/#{JBUpdater::GUI::Actions.total}): #{xml_id}")

      begin
        opts = JBUpdater::Options.new
        opts.install_ids = [xml_id]
        opts.plugins_dir = plugins_dir
        opts.build = build

        JBUpdater::HTTPClient.no_tty_progress_bar = true

        updater = JBUpdater::Updater.new(opts)
        updater.build = build
        updater.run(:install)

        status_msg = "✓ #{xml_id} installed successfully"
      rescue ex
        status_msg = "✖ #{xml_id} failed: #{ex.message}"
      end

      App.push_log("[Browser] #{status_msg}")

      completed = JBUpdater::GUI::Actions.total - JBUpdater::GUI::Actions.queue_size
      overall_pct = JBUpdater::GUI::Actions.total > 0 ? ((completed.to_f / JBUpdater::GUI::Actions.total) * 100).to_i : 100
      UIng.queue_main do
        App.overall_progress.value = overall_pct
      end
    end

    JBUpdater::GUI::Actions.processing = false
    UIng.queue_main do
      App.plugin_progress.value = 100
      App.overall_progress.value = 100
      App.busy = false
      App.debug_reenable
    end
  end
end

# Forces the log scrollbar to the bottom by re-assigning the text.
private def scroll_log(log : UIng::MultilineEntry)
  full_text = log.text || ""
  log.text = full_text
rescue
end

# Saves Plugins tab UI field values to config.
private def save_plugins_settings(
  e_plugins_dir : UIng::Entry,
  e_build : UIng::Entry,
  e_product : UIng::Entry,
  e_install_ids : UIng::Entry,
  combo_arch : UIng::Combobox,
  combo_products : UIng::Combobox,
  chk_dry : UIng::Checkbox,
)
  data = {} of String => String
  data["plugins_dir"] = e_plugins_dir.text || ""
  data["build"] = e_build.text || ""
  data["product"] = e_product.text || ""
  data["install_ids"] = e_install_ids.text || ""
  data["arch"] = combo_arch.selected.to_s
  data["combo_products_selected"] = combo_products.selected.to_s
  data["dry_run"] = chk_dry.checked?.to_s
  save_config(data)
end

# Saves IDE tab UI field values to config.
private def save_ide_settings(
  e_ide_product : UIng::Entry,
  e_ide_path : UIng::Entry,
  chk_brew : UIng::Checkbox,
)
  data = {} of String => String
  data["ide_product"] = e_ide_product.text || ""
  data["ide_path"] = e_ide_path.text || ""
  data["brew"] = chk_brew.checked?.to_s
  save_config(data)
end

# Restores Plugins tab field values from saved config.
private def apply_plugins_settings(
  e_plugins_dir : UIng::Entry,
  e_build : UIng::Entry,
  e_product : UIng::Entry,
  e_install_ids : UIng::Entry,
  combo_arch : UIng::Combobox,
  combo_products : UIng::Combobox,
  chk_dry : UIng::Checkbox,
  log : UIng::MultilineEntry,
)
  config = load_config
  e_plugins_dir.text = config.fetch("plugins_dir", "")
  e_build.text = config.fetch("build", "")
  e_product.text = config.fetch("product", "")
  e_install_ids.text = config.fetch("install_ids", "")
  arch = config.fetch("arch", "")
  if !arch.empty?
    combo_arch.selected = arch.to_i
  end
  selected = config.fetch("combo_products_selected", "")
  if !selected.empty?
    combo_products.selected = selected.to_i
  end
  chk_dry_val = config.fetch("dry_run", "")
  if chk_dry_val == "true"
    chk_dry.checked = true
  end
end

# Restores IDE tab field values from saved config.
private def apply_ide_settings(
  e_ide_product : UIng::Entry,
  e_ide_path : UIng::Entry,
  chk_brew : UIng::Checkbox,
)
  config = load_config
  val = config.fetch("ide_product", "")
  e_ide_product.text = val =~ /\A[A-Z]+-\d/ ? val : ""
  e_ide_path.text = config.fetch("ide_path", "")
  if config.fetch("brew", "") == "true"
    chk_brew.checked = true
  end
end

# ---- UI --------------------------------------------------------------
UIng.init do
  window = UIng::Window.new("JB Updater — JetBrains IDE & Plugin Manager", 960, 660)

  window.on_closing do
    App.mark_shutting_down
    UIng.quit
    true
  end

  root = UIng::Box.new(:vertical)
  root.padded = false
  window.set_child(root)

  pb_group = UIng::Group.new("Progress", margined: true)
  pb_inner = UIng::Box.new(:vertical)
  pb_inner.padded = true

  overall_label = UIng::Label.new("Overall:")
  overall_bar = UIng::ProgressBar.new
  overall_row = UIng::Box.new(:horizontal)
  overall_row.append(overall_label, false)
  overall_row.append(overall_bar, true)

  plugin_label = UIng::Label.new("Current plugin:")
  plugin_bar = UIng::ProgressBar.new
  plugin_row = UIng::Box.new(:horizontal)
  plugin_row.append(plugin_label, false)
  plugin_row.append(plugin_bar, true)

  pb_inner.append(overall_row, false)
  pb_inner.append(plugin_row, false)
  pb_group.child = pb_inner
  root.append(pb_group, false)

  sep1 = UIng::Separator.new("horizontal")
  root.append(sep1, false)

  tabs = UIng::Tab.new
  root.append(tabs, true)

  log = UIng::MultilineEntry.new(false, true)
  log.on_changed do
    scroll_log(log)
  end

  # Log all HTTP requests and Log.* messages to the console
  JBUpdater::HTTPClient.on_request = ->(method : String, url : String) {
    App.push_log("[HTTP] #{method} #{url}")
  }
  JBUpdater::HTTPClient.on_progress = ->(downloaded : Int64, total : Int64) {
    App.update_progress(downloaded, total)
  }
  JBUpdater::Log.listener = ->(msg : String) {
    App.push_log(msg)
  }

  sep2 = UIng::Separator.new("horizontal")
  root.append(sep2, false)

  actions_row = UIng::Box.new(:horizontal)
  actions_row.padded = true

  btn_clear_log = UIng::Button.new("Clear console")
  btn_remove_cache = UIng::Button.new("Remove *.bak* backups")
  debug_btn = UIng::Button.new("Debug: Re-enable UI")

  actions_row.append(btn_clear_log, false)
  actions_row.append(btn_remove_cache, false)
  actions_row.append(debug_btn, false)
  root.append(actions_row, false)

  status_label = UIng::Label.new("Ready")
  status_box = UIng::Box.new(:horizontal)
  status_box.padded = true
  status_box.append(status_label, true)
  root.append(status_box, false)

  btn_clear_log.on_clicked do
    UIng.queue_main do
      log.text = ""
      log.append("Console cleared at #{Time.local}\n")
      status_label.text = "Console cleared"
    end
  end

  debug_btn.on_clicked do
    UIng.queue_main do
      App.debug_reenable
      status_label.text = "UI re-enabled"
    end
  end

  # --- Plugins tab ----------------------------------------------------
  plugins_tab = UIng::Box.new(:vertical)
  plugins_tab.padded = true

  prod_group = UIng::Group.new("Product Detection", margined: true)
  prod_form = UIng::Form.new
  prod_form.padded = true

  combo_products = UIng::Combobox.new
  detected = JBUpdater::DetectProducts.all
  App.detected_products = detected

  detected.sort_by!(&.name)

  combo_products.append("Manual / Custom")
  detected.each do |prod|
    combo_products.append("#{prod.name} (#{prod.build})")
  end
  combo_products.selected = 0

  prod_form.append("IDE / Product", combo_products, false)
  prod_group.child = prod_form
  plugins_tab.append(prod_group, false)

  config_group = UIng::Group.new("Configuration", margined: true)
  config_form = UIng::Form.new
  config_form.padded = true

  e_plugins_dir = UIng::Entry.new
  e_build = UIng::Entry.new
  e_product = UIng::Entry.new
  e_install_ids = UIng::Entry.new

  combo_arch = UIng::Combobox.new
  ["Auto", "arm", "intel"].each { |arch_label| combo_arch.append arch_label }
  combo_arch.selected = 0

  config_form.append("Plugins dir", e_plugins_dir, true)
  config_form.append("Build", e_build, false)
  config_form.append("Product", e_product, false)
  config_form.append("Install IDs", e_install_ids, false)
  config_form.append("Arch", combo_arch, false)
  config_group.child = config_form
  plugins_tab.append(config_group, false)

  chk_dry = UIng::Checkbox.new("Dry run")
  plugins_tab.append(chk_dry, false)

  btn_group = UIng::Box.new(:vertical)
  btn_group.padded = true

  btn_detect = UIng::Button.new("Detect from Product")
  btn_detect.on_clicked do
    UIng.queue_main do
      product = e_product.text
      if product.nil? || product.empty?
        log.append("ERROR: Enter Product (e.g., RubyMine2025.2) before Detect.\n")
        status_label.text = "Error: missing product"
      else
        begin
          resolved = JBUpdater::Utils.resolve_product_folder(product)
          path = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
          e_plugins_dir.text = path
          log.append("Detected plugins dir: #{path}\n")
          status_label.text = "Detected: #{path}"
          save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
        rescue ex
          log.append("ERROR: #{ex.message}\n")
          status_label.text = "Error: #{ex.message}"
        end
      end
    end
  end
  btn_group.append(btn_detect, false)

  btn_group_sep = UIng::Separator.new("horizontal")
  btn_group.append(btn_group_sep, false)

  main_actions = UIng::Box.new(:horizontal)
  main_actions.padded = true

  btn_list = UIng::Button.new("List installed")
  btn_install = UIng::Button.new("Install by IDs")
  btn_update = UIng::Button.new("Update all")

  main_actions.append(btn_list, false)
  main_actions.append(btn_install, false)
  main_actions.append(btn_update, false)
  btn_group.append(main_actions, false)

  plugins_tab.append(btn_group, false)
  tabs.append("Plugins", plugins_tab)

  # --- Browse tab -----------------------------------------------------
  browse_tab = UIng::Box.new(:vertical)
  browse_tab.padded = true

  browse_content = UIng::Box.new(:horizontal)
  browse_content.padded = true

  browse_left = UIng::Box.new(:vertical)
  browse_left.padded = true

  browse_header = UIng::Box.new(:horizontal)
  browse_header.padded = true

  search_entry = UIng::Entry.new
  search_entry.text = ""

  btn_top = UIng::Button.new("Top Downloaded")
  btn_newest = UIng::Button.new("Newest")
  btn_refresh = UIng::Button.new("Refresh")

  browse_header.append(search_entry, true)
  browse_header.append(btn_top, false)
  browse_header.append(btn_newest, false)
  browse_header.append(btn_refresh, false)
  browse_left.append(browse_header, false)

  browse_model_handler = UIng::Table::Model::Handler.new do
    num_columns { 4 }
    column_type { |_col| UIng::Table::Value::Type::String }
    num_rows { App.browse_plugins.size }
    cell_value { |row, col|
      if row < App.browse_plugins.size
        plugin = App.browse_plugins[row]
        case col
        when 0 then UIng::Table::Value.new(plugin.name)
        when 1
          installed = App.installed_plugins
          value = installed ? (installed.has_key?(plugin.xml_id) ? "✓" : "") : "—"
          UIng::Table::Value.new(value)
        when 2 then UIng::Table::Value.new(plugin.formatted_downloads)
        else        UIng::Table::Value.new(plugin.star_rating)
        end
      else
        UIng::Table::Value.new("")
      end
    }
  end

  browse_model = UIng::Table::Model.new(browse_model_handler)
  browse_table = UIng::Table.new(browse_model)
  browse_table.header_visible = true
  browse_table.selection_mode = :one

  browse_table.append_text_column("Plugin", 0, -1)
  browse_table.append_text_column("Installed", 1, -1)
  browse_table.append_text_column("Downloads", 2, -1)
  browse_table.append_text_column("Rating", 3, -1)
  browse_table.column_set_width(0, 260)
  browse_table.column_set_width(1, 60)
  browse_table.column_set_width(2, 100)
  browse_table.column_set_width(3, 80)

  browse_table.on_header_clicked do |column|
    next unless {0, 2, 3}.includes?(column)

    (0...4).each do |col|
      browse_table.header_set_sort_indicator(col, :none) if col != column
    end

    current = browse_table.header_sort_indicator(column)
    ascending = current.none? || current.descending?

    plugins = App.browse_plugins
    case column
    when 0 then plugins.sort! { |x, y| ascending ? x.name <=> y.name : y.name <=> x.name }
    when 2 then plugins.sort! { |x, y| ascending ? x.downloads <=> y.downloads : y.downloads <=> x.downloads }
    when 3 then plugins.sort! { |x, y| ascending ? x.rating <=> y.rating : y.rating <=> x.rating }
    end

    new_indicator = ascending ? UIng::Table::SortIndicator::Ascending : UIng::Table::SortIndicator::Descending
    browse_table.header_set_sort_indicator(column, new_indicator)

    plugins.each_with_index { |_, i| browse_model.row_changed(i) }
  end

  browse_left.append(browse_table, true)

  App.browse_table_model = browse_model
  App.browse_handler = browse_model_handler

  browse_actions = UIng::Box.new(:horizontal)
  browse_actions.padded = true

  btn_install_browse = UIng::Button.new("Install Selected")
  btn_copy_id = UIng::Button.new("Copy XML ID")

  browse_actions.append(btn_install_browse, false)
  browse_actions.append(btn_copy_id, false)
  browse_left.append(browse_actions, false)

  browse_status = UIng::Label.new("Click search or a button to browse plugins")
  browse_status_box = UIng::Box.new(:horizontal)
  browse_status_box.padded = true
  browse_status_box.append(browse_status, true)
  browse_left.append(browse_status_box, false)

  browse_detail = UIng::MultilineEntry.new(true, true)
  browse_detail.text = "Select a plugin to view details"
  App.browse_detail = browse_detail
  browse_left.append(browse_detail, false)

  browse_content.append(browse_left, true)
  browse_tab.append(browse_content, true)

  tabs.append("Browse", browse_tab)

  # --- IDE tab --------------------------------------------------------
  ide_tab = UIng::Box.new(:vertical)
  ide_tab.padded = true

  ide_group = UIng::Group.new("IDE Configuration", margined: true)
  ide_form = UIng::Form.new
  ide_form.padded = true

  e_ide_product = UIng::Entry.new
  e_ide_path = UIng::Entry.new

  ide_form.append("IDE code or name", e_ide_product, false)
  ide_form.append("IDE Path", e_ide_path, true)
  ide_group.child = ide_form
  ide_tab.append(ide_group, false)

  chk_brew = UIng::Checkbox.new("Patch Homebrew cask (macOS)")
  ide_tab.append(chk_brew, false)

  ide_actions = UIng::Box.new(:vertical)
  ide_actions.padded = true

  btn_list_releases = UIng::Button.new("List releases")
  btn_upgrade = UIng::Button.new("Upgrade IDE")

  ide_actions.append(btn_list_releases, false)
  ide_actions.append(btn_upgrade, false)
  ide_tab.append(ide_actions, false)
  tabs.append("IDE", ide_tab)

  combo_products.on_selected do
    UIng.queue_main do
      idx = combo_products.selected
      if idx > 0
        prod = detected[idx - 1]
        log.append("[GUI] Selected product: #{prod.name} (#{prod.build})\n")

        if dir = prod.plugins_dir
          e_plugins_dir.text = dir
        end
        e_product.text = prod.name
        e_ide_product.text = prod.build
        if path = prod.ide_path
          e_ide_path.text = path
        end

        status_label.text = "Selected: #{prod.name}"
        save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
      else
        status_label.text = "Product selection: manual/custom"
      end
    end
  end

  all_buttons = [] of UIng::Button
  all_buttons.concat([btn_list, btn_install, btn_update])
  all_buttons.concat([btn_list_releases, btn_upgrade])
  App.set_widgets(log, overall_bar, plugin_bar, all_buttons)

  # Global timer: drain buffered log messages and update progress bars
  UIng.timer(150) do
    App.drain_log_buffer.each do |msg|
      App.log.append(msg + "\n")
    end
    pct = App.read_progress
    App.plugin_progress.value = pct if pct > 0
    1
  end

  apply_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry, log)
  apply_ide_settings(e_ide_product, e_ide_path, chk_brew)

  idx = combo_products.selected
  if idx > 0 && idx <= detected.size
    prod = detected[idx - 1]
    e_ide_product.text = prod.build
    log.append("[GUI] Restored product: #{prod.name} (#{prod.build})\n")
  end

  log.append("JB Updater GUI ready. Select a detected IDE or enter paths manually.\n")
  status_label.text = "Ready"

  btn_remove_cache.on_clicked do
    UIng.queue_main do
      raw = e_plugins_dir.text
      if raw.nil? || raw.empty?
        log.append("ERROR: Plugins dir is required for Remove cache.\n")
        status_label.text = "Error: missing plugins dir"
      else
        plugins_dir = expand_tilde(raw) || raw
        if !Dir.exists?(plugins_dir)
          log.append("ERROR: Plugins dir '#{plugins_dir}' does not exist.\n")
          status_label.text = "Error: dir not found"
        else
          begin
            removed = 0
            Dir.each_child(plugins_dir) do |entry|
              if entry.includes?(".bak")
                path = File.join(plugins_dir, entry)
                FileUtils.rm_rf(path)
                removed += 1
                log.append("Removed backup: #{path}\n")
              end
            end

            if removed == 0
              log.append("No *.bak* backup entries found under #{plugins_dir}\n")
              status_label.text = "No backups found"
            else
              log.append("Removed #{removed} backup entr#{removed == 1 ? "y" : "ies"} under #{plugins_dir}\n")
              status_label.text = "Removed #{removed} backup(s)"
            end
          rescue ex
            log.append("ERROR while removing cache: #{ex.class}: #{ex.message}\n")
            status_label.text = "Error during cache removal"
          end
        end
      end
    end
  end

  btn_list.on_clicked do
    UIng.queue_main do
      raw = e_plugins_dir.text
      if raw.nil? || raw.empty?
        log.append("ERROR: Plugins dir is required for List installed plugins.\n")
        status_label.text = "Error: missing plugins dir"
      else
        plugins_dir = expand_tilde(raw)
        e_plugins_dir.text = plugins_dir if plugins_dir
        args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new("")) + ["--list"]
        new_run_header("List installed plugins", args)
        run_cli(args)
        save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
      end
    end
  end

  btn_install.on_clicked do
    UIng.queue_main do
      raw = e_plugins_dir.text
      if raw.nil? || raw.empty?
        log.append("ERROR: Plugins dir is required for Install plugins.\n")
        status_label.text = "Error: missing plugins dir"
      else
        plugins_dir = expand_tilde(raw)
        e_plugins_dir.text = plugins_dir if plugins_dir
        args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""))
        new_run_header("Install plugins", args)
        run_cli(args)
        save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
      end
    end
  end

  btn_update.on_clicked do
    UIng.queue_main do
      raw = e_plugins_dir.text
      if raw.nil? || raw.empty?
        log.append("ERROR: Plugins dir is required for Update plugins.\n")
        status_label.text = "Error: missing plugins dir"
      else
        plugins_dir = expand_tilde(raw)
        e_plugins_dir.text = plugins_dir if plugins_dir
        args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""))
        new_run_header("Update plugins", args)
        run_cli(args)
        save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
      end
    end
  end

  btn_list_releases.on_clicked do
    UIng.queue_main do
      product = e_ide_product.text
      if product.nil? || product.empty?
        log.append("ERROR: IDE code is required for List releases (e.g., WS, RM).\n")
        status_label.text = "Error: missing IDE code"
      else
        args = ["--list-ide-releases", "--product", product]
        new_run_header("List IDE releases", args)
        run_cli(args)
        save_ide_settings(e_ide_product, e_ide_path, chk_brew)
      end
    end
  end

  btn_upgrade.on_clicked do
    UIng.queue_main do
      args = ["--upgrade-ide"]

      ide_product = e_ide_product.text
      ide_path = e_ide_path.text

      args += ["--product", ide_product] if ide_product && !ide_product.empty?
      args += ["--ide-path", ide_path] if ide_path && !ide_path.empty?
      args << "--brew" if chk_brew.checked?

      new_run_header("Upgrade IDE", args)
      run_cli(args)
      save_ide_settings(e_ide_product, e_ide_path, chk_brew)
    end
  end

  resolve_build = -> : String {
    products = App.detected_products || JBUpdater::DetectProducts.all
    result = JBUpdater::GUI::Actions.resolve_build(e_ide_product.text, e_build.text, products)
    if result != e_ide_product.text && result != e_build.text
      log.append("[Browse] Auto-detected build: #{result}\n")
    end
    result
  }

  # Preload installed plugins on main thread at startup
  load_installed_for_browse = -> {
    App.installed_plugins = nil
    raw = e_plugins_dir.text
    if raw && !raw.empty?
      dir = expand_tilde(raw) || raw
      App.installed_plugins = JBUpdater::PluginMeta.scan_dir(dir) rescue nil
    end
  }
  load_installed_for_browse.call

  # Warm marketplace cache after UI is visible (1s delay)
  UIng.timer(1_000) {
    build = resolve_build.call
    JBUpdater::PluginMarketplace.list_by_build(build)
    log.append("[Browse] Marketplace cache warmed: #{build}\n")
    0
  }

  search_entry.on_changed do |_text|
    begin
      query = search_entry.text
      if query.nil? || query.empty?
        model = App.browse_table_model
        if model
          old_count = App.browse_plugins.size
          (0...old_count).each { |i| model.row_deleted(i) }
        end
        App.browse_plugins = [] of JBUpdater::PluginInfo
        App.selected_xml_id = nil
        browse_status.text = "Type to search plugins..."
        next
      end

      build = resolve_build.call
      plugins = JBUpdater::PluginMarketplace.search(query, build)

      model = App.browse_table_model
      next unless model

      old_count = App.browse_plugins.size
      App.browse_plugins = plugins
      if old_count == 0
        plugins.each_with_index { |_, i| model.row_inserted(i) }
      elsif plugins.size >= old_count
        (0...old_count).each { |i| model.row_changed(i) }
        (old_count...plugins.size).each { |i| model.row_inserted(i) }
      else
        (0...plugins.size).each { |i| model.row_changed(i) }
        (plugins.size...old_count).each { |i| model.row_deleted(i) }
      end
      browse_status.text = "Found #{plugins.size} results for '#{query}'"
      log.append("[Browse] Found #{plugins.size} plugins for '#{query}'\n")
      plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }
    rescue ex
      log.append("[Browse] Search error: #{ex.message}\n")
      browse_status.text = "Search error: #{ex.message}"
    end
  end

  btn_top.on_clicked do
    build = resolve_build.call
    browse_status.text = "Fetching top plugins (may lag)..."
    log.append("[Browse] Fetching top downloaded for build #{build}...\n")
    plugins = JBUpdater::PluginMarketplace.top_downloaded(build, 100)
    log.append("[Browse] Got #{plugins.size} plugins, updating table...\n")
    plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }

    model = App.browse_table_model
    next unless model

    old_count = App.browse_plugins.size
    App.browse_plugins = plugins
    if old_count == 0
      plugins.each_with_index { |_, i| model.row_inserted(i) }
    elsif plugins.size >= old_count
      (0...old_count).each { |i| model.row_changed(i) }
      (old_count...plugins.size).each { |i| model.row_inserted(i) }
    else
      (0...plugins.size).each { |i| model.row_changed(i) }
      (plugins.size...old_count).each { |i| model.row_deleted(i) }
    end
    browse_status.text = "Loaded #{plugins.size} plugins (top downloads)"
  end

  btn_newest.on_clicked do
    build = resolve_build.call
    browse_status.text = "Fetching latest plugins..."
    log.append("[Browse] Fetching newest for build #{build}...\n")
    plugins = JBUpdater::PluginMarketplace.newest(build, 100)
    log.append("[Browse] Got #{plugins.size} plugins, updating table...\n")
    plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }

    model = App.browse_table_model
    next unless model

    old_count = App.browse_plugins.size
    App.browse_plugins = plugins
    if old_count == 0
      plugins.each_with_index { |_, i| model.row_inserted(i) }
    elsif plugins.size >= old_count
      (0...old_count).each { |i| model.row_changed(i) }
      (old_count...plugins.size).each { |i| model.row_inserted(i) }
    else
      (0...plugins.size).each { |i| model.row_changed(i) }
      (plugins.size...old_count).each { |i| model.row_deleted(i) }
    end
    browse_status.text = "Loaded #{plugins.size} plugins (latest)"
  end

  btn_refresh.on_clicked do
    UIng.queue_main do
      App.installed_plugins = nil
      model = App.browse_table_model
      if model
        old_count = App.browse_plugins.size
        (0...old_count).each { |i| model.row_deleted(i) }
        App.browse_plugins = [] of JBUpdater::PluginInfo
        App.selected_xml_id = nil
        JBUpdater::PluginMarketplace.clear_cache
        browse_status.text = "Cache cleared. Click Top/Refresh to reload."
      end
    end
  end

  browse_table.on_selection_changed do |selection|
    row = selection.num_rows > 0 ? selection.rows[0] : -1
    if row >= 0
      plugin = App.browse_plugins[row]?
      if plugin
        App.selected_xml_id = plugin.xml_id
        cats = plugin.categories.empty? ? "no categories" : plugin.categories[0..2].join(", ")
        stripped = JBUpdater::PluginMarketplace.html_strip(plugin.description)
        browse_detail.text = stripped[0..200]
        browse_status.text = "#{plugin.name} — #{stripped[0..80]}... [#{plugin.formatted_downloads} dl] [#{cats}]"
      end
    else
      browse_detail.text = "Select a plugin to view details"
      App.selected_xml_id = nil
    end
  end

  btn_install_browse.on_clicked do
    xml_id = App.selected_xml_id
    if xml_id.nil? || xml_id.empty?
      browse_status.text = "Please select a plugin first"
      next
    end

    plugins_dir = e_plugins_dir.text
    if plugins_dir.nil? || plugins_dir.empty?
      browse_status.text = "Error: plugins dir not set. Switch to Plugins tab."
      next
    end

    build = resolve_build.call

    log.append("[Browse] Installing plugin: #{xml_id} for build #{build}\n")

    queue_install(xml_id, plugins_dir, build)
  end

  btn_copy_id.on_clicked do
    xml_id = App.selected_xml_id
    if xml_id.nil? || xml_id.empty?
      browse_status.text = "Please select a plugin first"
    else
      log.append("[Browse] Copied XML ID: #{xml_id}\n")
      browse_status.text = "Copied to clipboard: #{xml_id}"
    end
  end

  window.show
  UIng.main
end
