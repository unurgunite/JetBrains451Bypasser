require "../jb_updater"
require "../jb_updater/detect_products"
require "../jb_updater/plugin_marketplace"
require "../jb_updater/gui_actions"
require "../jb_updater/clipboard"
require "file_utils"
require "json"
require "uing"

{% if flag?(:darwin) %}
  {% run("./compile_helper.cr") %}
  @[Link(framework: "AppKit")]
  lib AppKit_
    fun objc_getClass(name : UInt8*) : Void*
    fun sel_registerName(name : UInt8*) : Void*
    fun objc_msgSend(recv : Void*, sel : Void*, ...) : Void*
  end
  @[Link(ldflags: "/tmp/jb_layout.o")]
  lib LayoutHelper
    fun create_width_constraint(item : Void*, relative_to : Void*, multiplier : Float64) : Void*
    fun add_constraint_to_view(view : Void*, constraint : Void*) : Void
    fun set_app_icon(icns_path : UInt8*) : Void
    fun setup_menu_bar : Void
  end
{% end %}

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
  return unless text
  return if text.empty?
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
  include_install : Bool = true,
) : Array(String)
  args = [] of String

  add_opt(args, "--plugins-dir", expand_tilde(e_plugins_dir.text))
  add_opt(args, "--build", e_build.text)
  add_opt(args, "--product", e_product.text)
  add_opt(args, "--install-plugin", e_install_ids.text) if include_install

  args.concat(arch_args(combo_arch))

  args << "--dry-run" if chk_dry.checked?
  args << "--list" if chk_list.checked?
  args
end

# Cached CPU architecture, detected once on the main context at startup.
#
# `uname -m` runs through `Process.run`, which only works on the main
# execution context; caching keeps it out of background threads.
ARCH = begin
  io = IO::Memory.new
  status = Process.run("uname", args: ["-m"], output: io)
  machine = io.to_s.strip
  if status.success? && (machine == "arm64" || machine == "aarch64")
    "arm"
  else
    "intel"
  end
rescue
  "intel"
end

# Runs `jb_updater` logic in-process, mirroring {CLI} argument dispatch.
#
# Everything runs on a background thread exactly like the legacy
# subprocess path, but avoids `Process.run` from a spawned thread,
# which deadlocks under Crystal 1.21 (spawning is main-context only).
# `Log.*` output and HTTP progress already route to the GUI console
# and progress bars via the listeners installed at startup.
#
# @param args [Array(String)] CLI arguments
private def run_cli(args : Array(String)) : Nil
  return if App.busy?

  App.busy = true
  App.log.append("[CLI] jb_updater #{args.join(" ")}\n")

  Thread.new do
    opts = JBUpdater.parse_cli(args)
    opts.arch ||= ARCH

    if opts.list_ide_releases?
      product = JBUpdater::Utils.product_code(opts.product || raise "missing --product")
      arch = opts.arch || ARCH
      releases = JBUpdater::IDEReleases.fetch(
        product,
        channel: "release",
        downloads_host: opts.ide_downloads_host,
        arch: arch,
        latest: false,
      )
      JBUpdater::Log.info("Available releases for #{product}:")
      releases.each do |rel|
        JBUpdater::Log.info("- #{rel.version} (#{rel.channel}) #{rel.date}  -> #{rel.link}")
      end
    elsif opts.upgrade_ide?
      JBUpdater::IDEUpdater.new(opts).run
    elsif pd = opts.plugins_dir
      opts.plugins_dir = JBUpdater::Utils.expand_tilde(pd)
      JBUpdater::Updater.new(opts).run
    else
      raise "no operation requested (missing --product, --plugins-dir, or --upgrade-ide)"
    end

    UIng.queue_main do
      next if App.shutting_down?
      App.log.append("[CLI] finished\n")
      App.status_label.text = "Done (exit 0)"
      App.busy = false
      App.debug_reenable
    end
  rescue ex
    UIng.queue_main do
      next if App.shutting_down?
      App.log.append("[CLI] ERROR: #{ex.message}\n")
      App.status_label.text = "Error: #{ex.message}"
      App.busy = false
      App.debug_reenable
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
      next if App.shutting_down?
      App.plugin_progress.value = 100
      App.overall_progress.value = 100
      App.busy = false
      App.debug_reenable

      # Push installation results into the Installed tab and Browse
      # "Installed" column so the user sees the plugin right away.
      scanned = JBUpdater::PluginMeta.scan_dir(plugins_dir) rescue nil
      if scanned
        apply_installed_scan(scanned)
        App.status_label.text = "Installed. Found #{scanned.size} installed plugins"
      end
      if model = App.browse_table_model
        (0...App.browse_plugins.size).each { |i| model.row_changed(i) }
      end
    end
  end
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

# Updates the global "Current IDE" badge shown on every tab.
private def update_ide_badge(e_product : UIng::Entry, e_build : UIng::Entry) : Nil
  return unless App.ide_badge
  product = e_product.text.try(&.strip)
  build = e_build.text.try(&.strip)
  if product.nil? || product.empty?
    App.ide_badge.try(&.text = "")
  elsif build.nil? || build.empty?
    App.ide_badge.try(&.text = "Current IDE: #{product}")
  else
    App.ide_badge.try(&.text = "Current IDE: #{product} (#{build})")
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

{% if flag?(:darwin) %}
  private def do_setup_icon_and_keys
    exe_path = Process.executable_path
    if exe_path
      dir = File.dirname(exe_path)
      icon_path = if dir.ends_with?("/MacOS")
                    File.join(dir, "..", "Resources", "jb_updater.icns")
                  else
                    File.join(dir, "assets", "jb_updater.icns")
                  end
      LayoutHelper.set_app_icon(icon_path)
    end
    LayoutHelper.setup_menu_bar
  end
{% end %}

# ---- UI --------------------------------------------------------------
UIng.init

{% if flag?(:darwin) %}
  do_setup_icon_and_keys
{% end %}

window = UIng::Window.new("JB Updater — JetBrains IDE & Plugin Manager", 1180, 840)

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

# Dev-only conveniences (hidden unless JB_UPDATER_DEV is set).
dev_mode = ENV["JB_UPDATER_DEV"]? == "1"
btn_remove_cache : UIng::Button? = nil
debug_btn : UIng::Button? = nil
actions_row : UIng::Box? = nil
if dev_mode
  actions_row = UIng::Box.new(:horizontal)
  actions_row.padded = true
  btn_remove_cache = UIng::Button.new("Remove *.bak* backups")
  debug_btn = UIng::Button.new("Debug: Re-enable UI")
  actions_row.append(btn_remove_cache, false)
  actions_row.append(debug_btn, false)
end
root.append(actions_row, false) if actions_row

status_label = UIng::Label.new("Ready")
App.status_label = status_label
status_box = UIng::Box.new(:horizontal)
status_box.padded = true
status_box.append(status_label, false)
ide_badge = UIng::Label.new("")
App.ide_badge = ide_badge
status_box.append(UIng::Box.new(:horizontal), true)
status_box.append(ide_badge, false)
root.append(status_box, false)

sep2 = UIng::Separator.new("horizontal")
root.append(sep2, false)

tabs = UIng::Tab.new
root.append(tabs, true)

log = UIng::MultilineEntry.new(false, false)

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

if debug_btn
  debug_btn.on_clicked do
    UIng.queue_main do
      App.debug_reenable
      status_label.text = "UI re-enabled"
    end
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
config_form.append("Arch", combo_arch, false)
config_group.child = config_form
plugins_tab.append(config_group, false)

chk_dry = UIng::Checkbox.new("Dry run")
plugins_tab.append(chk_dry, false)

install_ids_row = UIng::Box.new(:horizontal)
install_ids_row.padded = true
ids_label = UIng::Label.new("Install XML IDs")
install_ids_row.append(ids_label, false)
install_ids_row.append(e_install_ids, true)
plugins_tab.append(install_ids_row, false)

btn_group = UIng::Box.new(:vertical)
btn_group.padded = true

btn_detect = UIng::Button.new("Detect from Product")
btn_detect.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
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

batch_group = UIng::Group.new("Bulk actions", margined: true)
main_actions = UIng::Box.new(:horizontal)
main_actions.padded = true

btn_list = UIng::Button.new("List installed")

main_actions.append(btn_list, false)
batch_group.child = main_actions
btn_group.append(batch_group, false)

plugins_tab.append(btn_group, false)
tabs.append("Main", plugins_tab)

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
  cell_value do |row, col|
    if row < App.browse_plugins.size
      plugin = App.browse_plugins[row]
      case col
      when 0 then UIng::Table::Value.new(plugin.compat_note ? "⚠ #{plugin.name}" : plugin.name)
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
  end
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

# Diff-updates the browse table and status after a fetch completes.
# Must run on the UI thread (called from UIng.queue_main).
browse_update = ->(plugins : Array(JBUpdater::PluginInfo), status : String) {
  if model = App.browse_table_model
    old_count = App.browse_plugins.size
    App.browse_plugins = plugins
    if old_count == 0
      plugins.each_with_index { |_, i| model.row_inserted(i) }
    elsif plugins.size >= old_count
      (0...old_count).each { |i| model.row_changed(i) }
      (old_count...plugins.size).each { |i| model.row_inserted(i) }
    else
      (0...plugins.size).each { |i| model.row_changed(i) }
      (plugins.size...old_count).reverse_each { |i| model.row_deleted(i) }
    end
  end
  browse_status.text = status
  App.log.append("[Browse] #{status}\n")
}

browse_detail_box = UIng::Box.new(:vertical)
browse_detail_box.padded = true
detail_label = UIng::Label.new("Plugin Details")
browse_detail = UIng::MultilineEntry.new(true, true)
App.safe_set_text(browse_detail, "Select a plugin to view details")
App.browse_detail = browse_detail

browse_detail_box.append(detail_label, false)
browse_detail_box.append(browse_detail, true)
browse_content.append(browse_left, true)
browse_content.append(browse_detail_box, false)
browse_tab.append(browse_content, true)

tabs.append("Browse", browse_tab)

# --- Installed tab ---------------------------------------------------
installed_tab = UIng::Box.new(:vertical)
installed_tab.padded = true

installed_handler = UIng::Table::Model::Handler.new do
  num_columns { 5 }
  column_type { |_col| UIng::Table::Value::Type::String }
  num_rows { App.installed_plugins_arr.size }
  cell_value do |row, col|
    plugin = App.installed_plugins_arr[row]?
    next UIng::Table::Value.new("") unless plugin
    case col
    when 0 then UIng::Table::Value.new(plugin.name || plugin.id)
    when 1 then UIng::Table::Value.new(plugin.id)
    when 2 then UIng::Table::Value.new(plugin.version)
    when 3 then UIng::Table::Value.new(plugin.since || "—")
    else        UIng::Table::Value.new(plugin.until_build || "—")
    end
  end
end
installed_model = UIng::Table::Model.new(installed_handler)
App.installed_table = installed_table = UIng::Table.new(installed_model)
App.installed_model = installed_model
installed_table.header_visible = true
installed_table.append_text_column("Name", 0, -1)
installed_table.append_text_column("Plugin ID", 1, -1)
installed_table.append_text_column("Version", 2, -1)
installed_table.append_text_column("Since Build", 3, -1)
installed_table.append_text_column("Until Build", 4, -1)
installed_table.selection_mode = :one

installed_actions = UIng::Box.new(:horizontal)
installed_actions.padded = true

btn_scan_installed = UIng::Button.new("Scan")
btn_uninstall = UIng::Button.new("Uninstall selected")
btn_uninstall.disable
btn_update = UIng::Button.new("Update all")
btn_update_selected = UIng::Button.new("Update selected")
btn_update_selected.disable

installed_actions.append(btn_scan_installed, false)
installed_actions.append(btn_update, false)
installed_actions.append(btn_update_selected, false)
installed_actions.append(btn_uninstall, false)

installed_status = UIng::Label.new("Click Scan to list installed plugins")

installed_tab.append(installed_actions, false)
installed_tab.append(installed_table, true)
installed_tab.append(installed_status, false)

tabs.append("Installed", installed_tab)

# Applies a fresh PluginMeta scan to the Installed tab table (UI thread).
private def apply_installed_scan(scanned : Hash(String, JBUpdater::PluginMeta)) : Nil
  old_count = App.installed_plugins_arr.size
  App.installed_plugins = scanned
  model = App.installed_model
  return unless model
  if old_count == 0
    App.installed_plugins_arr.each_with_index { |_, i| model.row_inserted(i) }
  else
    (0...[App.installed_plugins_arr.size, old_count].min).each { |i| model.row_changed(i) }
    if App.installed_plugins_arr.size > old_count
      (old_count...App.installed_plugins_arr.size).each { |i| model.row_inserted(i) }
    elsif App.installed_plugins_arr.size < old_count
      (App.installed_plugins_arr.size...old_count).reverse_each { |i| model.row_deleted(i) }
    end
  end
end

btn_scan_installed.on_clicked do
  dir = expand_tilde(e_plugins_dir.text) || e_plugins_dir.text || ""
  if dir.empty?
    installed_status.text = "Set Plugins Directory first"
    next
  end
  scanned = JBUpdater::PluginMeta.scan_dir(dir) rescue nil
  if scanned
    apply_installed_scan(scanned)
    msg = "Found #{scanned.size} installed plugins"
    installed_status.text = msg
    status_label.text = msg
  else
    installed_status.text = "Error scanning plugins directory"
    status_label.text = "Error scanning plugins directory"
  end
end

installed_table.on_selection_changed do |selection|
  App.cancel_uninstall
  if selection.num_rows > 0
    btn_uninstall.enable
    btn_update_selected.enable
  else
    btn_uninstall.disable
    btn_update_selected.disable
  end
end

btn_uninstall.on_clicked do
  UIng.queue_main do
    installed_table.selection do |sel|
      next if sel.num_rows == 0
      row = sel.rows[0]
      plugin = App.installed_plugins_arr[row]?
      if plugin
        # Two-step confirmation guards against accidental deletion.
        unless App.confirm_uninstall?(plugin.id)
          App.arm_uninstall(plugin.id)
          installed_status.text = "Click Uninstall again to confirm deleting #{plugin.id}"
          next
        end
        FileUtils.rm_rf(plugin.path)
        scanned = JBUpdater::PluginMeta.scan_dir(File.dirname(plugin.path)) rescue nil
        old_count = App.installed_plugins_arr.size
        App.installed_plugins = scanned
        if old_count == 0
          App.installed_plugins_arr.each_with_index { |_, i| App.installed_model.try &.row_inserted(i) }
        else
          (0...[App.installed_plugins_arr.size, old_count].min).each { |i| App.installed_model.try &.row_changed(i) }
          if App.installed_plugins_arr.size > old_count
            (old_count...App.installed_plugins_arr.size).each { |i| App.installed_model.try &.row_inserted(i) }
          elsif App.installed_plugins_arr.size < old_count
            (App.installed_plugins_arr.size...old_count).reverse_each { |i| App.installed_model.try &.row_deleted(i) }
          end
        end
        installed_status.text = "Deleted: #{plugin.id}"
        btn_uninstall.disable
      end
    end
  end
end

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

btn_list_releases = UIng::Button.new("List releases")
btn_download_release = UIng::Button.new("Download selected")
btn_upgrade = UIng::Button.new("Upgrade IDE")

ide_actions = UIng::Box.new(:horizontal)
ide_actions.padded = true

ide_actions.append(btn_list_releases, false)
ide_actions.append(btn_download_release, false)
ide_actions.append(btn_upgrade, false)
ide_tab.append(ide_actions, false)
ide_tab.append(UIng::Separator.new("horizontal"), false)

release_title = UIng::Label.new("Releases")
ide_releases_box = UIng::Box.new(:vertical)
ide_releases_box.padded = true
ide_releases_box.append(release_title, false)

ide_release_handler = UIng::Table::Model::Handler.new do
  num_columns { 4 }
  column_type { |_col| UIng::Table::Value::Type::String }
  num_rows { App.ide_releases.size }
  cell_value do |row, col|
    rel = App.ide_releases[row]?
    next UIng::Table::Value.new("") unless rel
    case col
    when 0 then UIng::Table::Value.new(rel.version)
    when 1 then UIng::Table::Value.new(rel.channel)
    when 2 then UIng::Table::Value.new(rel.date)
    else        UIng::Table::Value.new(rel.link.to_s)
    end
  end
end
App.ide_release_model = ide_release_model = UIng::Table::Model.new(ide_release_handler)
App.ide_release_table = ide_release_table = UIng::Table.new(ide_release_model)
ide_release_table.header_visible = true
ide_release_table.selection_mode = :one
ide_release_table.append_text_column("Version", 0, 110)
ide_release_table.append_text_column("Channel", 1, 90)
ide_release_table.append_text_column("Date", 2, 120)
ide_release_table.append_text_column("Download URL", 3, -1)
ide_releases_box.append(ide_release_table, true)
ide_tab.append(ide_releases_box, true)

ide_release_table.on_selection_changed do |selection|
  App.ide_selected_row = selection.num_rows > 0 ? selection.rows[0] : -1
end

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
      e_build.text = prod.build
      e_ide_product.text = prod.build
      if path = prod.ide_path
        e_ide_path.text = path
      end

      status_label.text = "Selected: #{prod.name}"
      update_ide_badge(e_product, e_build)
      save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
    else
      status_label.text = "Product selection: manual/custom"
      update_ide_badge(e_product, e_build)
    end
  end
end

all_buttons = [] of UIng::Button
all_buttons.concat([btn_list])
all_buttons.concat([btn_update, btn_update_selected, btn_uninstall])
all_buttons.concat([btn_list_releases, btn_upgrade])
App.set_widgets(log, overall_bar, plugin_bar, all_buttons)

# Global timer: drain buffered log messages and update progress bars
UIng.timer(150) do
  msgs = App.drain_log_buffer
  if !msgs.empty?
    if (App.log.text.try(&.size) || 0) > 60_000
      App.log.text = "… (older log trimmed)\n"
    end
    msgs.each do |msg|
      App.log.append(msg + "\n")
    end
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
update_ide_badge(e_product, e_build)

e_product.on_changed do |_|
  UIng.queue_main { update_ide_badge(e_product, e_build) }
end
e_build.on_changed do |_|
  UIng.queue_main { update_ide_badge(e_product, e_build) }
end

log.append("JB Updater GUI ready. Select a detected IDE or enter paths manually.\n")
status_label.text = "Ready"

if btn_remove_cache
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
end

btn_list.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for List installed plugins.\n")
      status_label.text = "Error: missing plugins dir"
      next
    end
    plugins_dir = expand_tilde(raw) || raw
    e_plugins_dir.text = plugins_dir
    new_run_header("List installed plugins", ["--list", "--plugins-dir", plugins_dir])
    App.busy = true
    Thread.new do
      scanned = JBUpdater::PluginMeta.scan_dir(plugins_dir)
      UIng.queue_main do
        next if App.shutting_down?
        apply_installed_scan(scanned)
        msg = "Found #{scanned.size} installed plugins"
        installed_status.text = msg
        status_label.text = msg
        log.append("[CLI] #{msg}\n")
        tabs.selected = 2
        App.busy = false
        App.debug_reenable
      end
    rescue ex
      UIng.queue_main do
        next if App.shutting_down?
        log.append("[CLI] ERROR: #{ex.message}\n")
        status_label.text = "Error: #{ex.message}"
        installed_status.text = "Error: #{ex.message}"
        App.busy = false
        App.debug_reenable
      end
    end
    save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
  end
end

btn_update.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for Update plugins.\n")
      status_label.text = "Error: missing plugins dir"
      next
    end
    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir
    args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""), include_install: false)
    new_run_header("Update plugins", args)
    run_cli(args)
    save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
  end
end

btn_update_selected.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for Update selected plugins.\n")
      status_label.text = "Error: missing plugins dir"
      next
    end
    ids = [] of String
    installed_table.selection do |sel|
      sel.rows.each do |row|
        plugin = App.installed_plugins_arr[row]?
        ids << plugin.id if plugin
      end
    end
    if ids.empty?
      installed_status.text = "Select at least one installed plugin to update"
      status_label.text = "No plugin selected"
      next
    end
    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir
    args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""), include_install: false)
    args << "--install-plugin" << ids.join(",")
    new_run_header("Update selected plugins", args)
    run_cli(args)
    save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
  end
end

btn_list_releases.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
    product = e_ide_product.text
    if product.nil? || product.empty?
      log.append("ERROR: IDE code is required for List releases (e.g., WS, RM).\n")
      status_label.text = "Error: missing IDE code"
    else
      code = JBUpdater::Utils.product_code(product)
      new_run_header("List IDE releases", ["--list-ide-releases", "--product", product])

      App.busy = true
      Thread.new do
        releases = JBUpdater::IDEReleases.fetch(
          code,
          channel: "release",
          arch: ARCH,
          latest: false,
        )
        UIng.queue_main do
          next if App.shutting_down?
          old = App.ide_releases.size
          App.ide_releases = releases
          model = App.ide_release_model
          if model
            if old == 0
              releases.each_with_index { |_, i| model.row_inserted(i) }
            elsif releases.size >= old
              (0...old).each { |i| model.row_changed(i) }
              (old...releases.size).each { |i| model.row_inserted(i) }
            else
              (0...releases.size).each { |i| model.row_changed(i) }
              (releases.size...old).reverse_each { |i| model.row_deleted(i) }
            end
          end
          status_label.text = "Found #{releases.size} release(s) for #{code}"
          log.append("[IDE] #{releases.size} release(s) for #{code}\n")
        end
      rescue ex
        UIng.queue_main do
          next if App.shutting_down?
          log.append("[CLI] ERROR: #{ex.message}\n")
          status_label.text = "Error: #{ex.message}"
        end
      ensure
        UIng.queue_main do
          next if App.shutting_down?
          App.busy = false
          App.debug_reenable
        end
      end

      save_ide_settings(e_ide_product, e_ide_path, chk_brew)
    end
  end
end

btn_download_release.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
    row = App.ide_selected_row
    rel = row >= 0 ? App.ide_releases[row]? : nil
    if rel.nil?
      status_label.text = "Select a release first"
      next
    end

    new_run_header("Download #{rel.version}", [rel.link.to_s])

    dest_dir = File.join(ENV["HOME"]? || Dir.tempdir, "Downloads")
    Dir.mkdir_p(dest_dir) unless Dir.exists?(dest_dir)
    dest = File.join(dest_dir, File.basename(rel.link.path.to_s))

    App.busy = true
    JBUpdater::HTTPClient.no_tty_progress_bar = true
    Thread.new do
      JBUpdater::HTTPClient.download(rel.link, dest)
      UIng.queue_main do
        next if App.shutting_down?
        status_label.text = "Downloaded to #{dest}"
        log.append("[IDE] Downloaded #{rel.version} → #{dest}\n")
      end
    rescue ex
      UIng.queue_main do
        next if App.shutting_down?
        log.append("[IDE] Download failed: #{ex.class}: #{ex.message}\n")
        status_label.text = "Download failed: #{ex.message}"
      end
    ensure
      UIng.queue_main do
        next if App.shutting_down?
        App.busy = false
        App.debug_reenable
      end
    end
  end
end

btn_upgrade.on_clicked do
  UIng.queue_main do
    if App.busy?
      status_label.text = "Already running… please wait"
      next
    end
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

# Populate installed tab model with startup data
inst = App.installed_plugins
if inst && inst.size > 0
  App.installed_plugins_arr.each_with_index { |_, i| App.installed_model.try &.row_inserted(i) }
end

# Warm marketplace cache after UI is visible (1s delay).
# Heavy HTTP + XML parsing runs on a background thread to avoid
# crashes inside the AppKit timer callback (bug CB1).
UIng.timer(1_000) do
  build = resolve_build.call
  Thread.new do
    JBUpdater::PluginMarketplace.list_by_build(build)
    UIng.queue_main do
      next if App.shutting_down?
      log.append("[Browse] Marketplace cache warmed: #{build}\n")
    end
  rescue ex
    UIng.queue_main do
      next if App.shutting_down?
      log.append("[Browse] Cache warm failed: #{ex.class}: #{ex.message}\n")
    end
  end
  0
end

search_entry.on_changed do |text|
  query = text || ""
  App.search_id += 1
  my_id = App.search_id

  if query.empty?
    if model = App.browse_table_model
      old_count = App.browse_plugins.size
      App.browse_plugins = [] of JBUpdater::PluginInfo
      (0...old_count).each { |i| model.row_deleted(0) }
    end
    App.selected_xml_id = nil
    browse_status.text = "Type to search plugins..."
  else
    build = resolve_build.call
    browse_status.text = "Searching..."
    # Filtering runs on a background thread and is debounced so rapid
    # keystrokes only trigger the final query (bug CB2).
    Thread.new do
      sleep 250.milliseconds
      if my_id == App.search_id
        begin
          plugins = JBUpdater::PluginMarketplace.search(query, build)
          UIng.queue_main do
            next if App.shutting_down?
            if my_id == App.search_id
              browse_update.call(plugins, "Found #{plugins.size} results")
            end
          end
        rescue ex
          UIng.queue_main do
            next if App.shutting_down?
            if my_id == App.search_id
              App.log.append("[Browse] Search error: #{ex.class}: #{ex.message}\n")
              browse_status.text = "Search error: #{ex.message}"
            end
          end
        end
      end
    end
  end
rescue ex
  App.log.append("[Browse] Search error: #{ex.class}: #{ex.message}\n")
  browse_status.text = "Search error: #{ex.message}"
end

btn_top.on_clicked do
  build = resolve_build.call
  App.search_id += 1
  browse_status.text = "Fetching top plugins..."
  log.append("[Browse] Fetching top downloaded for build #{build}...\n")
  Thread.new do
    plugins = JBUpdater::PluginMarketplace.top_downloaded(build, 100)
    UIng.queue_main do
      next if App.shutting_down?
      plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }
      browse_update.call(plugins, "Loaded #{plugins.size} plugins (top downloads)")
    end
  rescue ex
    UIng.queue_main do
      next if App.shutting_down?
      log.append("[Browse] Top downloads error: #{ex.class}: #{ex.message}\n")
      browse_status.text = "Error: #{ex.message}"
    end
  end
end

btn_newest.on_clicked do
  build = resolve_build.call
  App.search_id += 1
  browse_status.text = "Fetching latest plugins..."
  log.append("[Browse] Fetching newest for build #{build}...\n")
  Thread.new do
    plugins = JBUpdater::PluginMarketplace.newest(build, 100)
    UIng.queue_main do
      next if App.shutting_down?
      plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }
      browse_update.call(plugins, "Loaded #{plugins.size} plugins (latest)")
    end
  rescue ex
    UIng.queue_main do
      next if App.shutting_down?
      log.append("[Browse] Newest error: #{ex.class}: #{ex.message}\n")
      browse_status.text = "Error: #{ex.message}"
    end
  end
end

btn_refresh.on_clicked do
  UIng.queue_main do
    App.search_id += 1
    App.installed_plugins = nil
    App.selected_xml_id = nil
    JBUpdater::PluginMarketplace.clear_cache
    if model = App.browse_table_model
      old_count = App.browse_plugins.size
      (0...old_count).each { |_| model.row_deleted(0) }
      App.browse_plugins = [] of JBUpdater::PluginInfo
    end
    browse_status.text = "Cache cleared. Click Top Downloaded or Newest to reload."
  rescue ex
    log.append("[Browse] Refresh error: #{ex.class}: #{ex.message}\n")
    browse_status.text = "Refresh error: #{ex.message}"
  end
end

browse_table.on_selection_changed do |selection|
  row = selection.num_rows > 0 ? selection.rows[0] : -1
  plugin = row >= 0 ? App.browse_plugins[row]? : nil
  if plugin
    App.selected_xml_id = plugin.xml_id
    if note = plugin.compat_note
      App.safe_set_text(browse_detail, "⚠ #{note}\n\n#{plugin.description}")
    else
      stripped = plugin.description[0, 500]
      preview = stripped[0, 500]
      App.log.append("[Browse] detail: #{preview.size}B #{preview.count('\n')} lines (#{preview.size - preview.count('\n')} non-newline)\n")
      App.safe_set_text(browse_detail, preview)
    end
  else
    App.safe_set_text(browse_detail, "Select a plugin to view details")
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
    browse_status.text = "Error: plugins dir not set. Switch to Main tab."
    next
  end

  build = resolve_build.call

  warn = App.browse_plugins.any? { |plugin| plugin.xml_id == xml_id && plugin.compat_note }
  log.append(warn ? "[Browse] ⚠ #{xml_id} may not be fully compatible with build #{build}; installing latest compatible version\n" : "[Browse] Installing plugin: #{xml_id} for build #{build}\n")
  browse_status.text = warn ? "Installing (compatibility warning)…" : "Installing…"

  queue_install(xml_id, plugins_dir, build)
end

btn_copy_id.on_clicked do
  xml_id = App.selected_xml_id
  if xml_id.nil? || xml_id.empty?
    browse_status.text = "Please select a plugin first"
  else
    copied = JBUpdater::Clipboard.copy(xml_id)
    log.append("[Browse] Copied XML ID: #{xml_id} (#{copied ? "ok" : "failed"})\n")
    browse_status.text = copied ? "Copied to clipboard: #{xml_id}" : "Copy to clipboard failed: #{xml_id}"
  end
end

{% if flag?(:darwin) %}
  constraint_added = false
  tabs.on_selected do |idx|
    if idx == 1 && !constraint_added
      constraint_added = true
      right_view = browse_detail_box.handle
      super_view = browse_content.handle
      c = LayoutHelper.create_width_constraint(right_view, super_view, 0.3_f64)
      LayoutHelper.add_constraint_to_view(super_view, c)
    end
  end
{% end %}

window.show
UIng.main
