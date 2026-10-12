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
require "./app_state"
require "./settings"
require "./cli_runner"
require "./gui_ctx"
require "./tab_helpers"
require "./main_tab"
require "./browse_tab"
require "./installed_tab"
require "./ide_tab"

# ---- UI --------------------------------------------------------------
UIng.init

{% if flag?(:darwin) %}
  GuiTabHelpers.setup_icon_and_keys
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

# Shared widgets (created once, passed to tab builders).
e_plugins_dir = UIng::Entry.new
e_build = UIng::Entry.new
e_product = UIng::Entry.new
e_install_ids = UIng::Entry.new

combo_arch = UIng::Combobox.new
["Auto", "arm", "intel"].each { |arch_label| combo_arch.append arch_label }
combo_arch.selected = 0

combo_products = UIng::Combobox.new
detected = JBUpdater::DetectProducts.all
App.detected_products = detected
detected.sort_by!(&.name)
combo_products.append("Manual / Custom")
detected.each do |prod|
  combo_products.append("#{prod.name} (#{prod.build})")
end
combo_products.selected = 0

chk_dry = UIng::Checkbox.new("Dry run")
e_ide_product = UIng::Entry.new
e_ide_path = UIng::Entry.new
chk_brew = UIng::Checkbox.new("Patch Homebrew cask (macOS)")

ctx = GuiCtx.new(
  log, status_label, tabs,
  e_plugins_dir, e_build, e_product, e_install_ids,
  combo_arch, combo_products, chk_dry,
  e_ide_product, e_ide_path, chk_brew,
  detected
)

tabs.append("Main", MainTab.build(ctx))
browse_parts = BrowseTab.build(ctx)
tabs.append("Browse", browse_parts[:box])
tabs.append("Installed", InstalledTab.build(ctx))
tabs.append("IDE", IdeTab.build(ctx))

browse_content = browse_parts[:content]
browse_detail_box = browse_parts[:detail_box]

App.set_widgets(log, overall_bar, plugin_bar, [] of UIng::Button)

# Global timer: drain buffered log messages and update progress bars
UIng.timer(150) do
  msgs = App.drain_log_buffer
  if !msgs.empty?
    if (App.log.text.try(&.size) || 0) > 60_000
      App.log.text = "… (older log trimmed)\n"
    end
    unless msgs.empty?
      App.log.append(String.build do |io|
        msgs.each do |msg|
          io << msg << "\n"
        end
      end)
    end
  end
  pct = App.read_progress
  App.plugin_progress.value = pct if pct > 0
  1
end

GuiTabHelpers.apply_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry, log)
GuiTabHelpers.apply_ide_settings(e_ide_product, e_ide_path, chk_brew)

idx = combo_products.selected
if idx > 0 && idx <= detected.size
  prod = detected[idx - 1]
  e_ide_product.text = prod.build
  log.append("[GUI] Restored product: #{prod.name} (#{prod.build})\n")
end
GuiTabHelpers.update_ide_badge(e_product, e_build)

e_product.on_changed do |_|
  UIng.queue_main { GuiTabHelpers.update_ide_badge(e_product, e_build) }
end
e_build.on_changed do |_|
  UIng.queue_main { GuiTabHelpers.update_ide_badge(e_product, e_build) }
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
        plugins_dir = GuiSettings.expand_tilde(raw) || raw
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

# Warm marketplace cache after UI is visible (1s delay).
# Heavy HTTP + XML parsing runs on a background thread to avoid
# crashes inside the AppKit timer callback (bug CB1).
resolve_build = -> : String {
  products = App.detected_products || JBUpdater::DetectProducts.all
  result = JBUpdater::GUI::Actions.resolve_build(e_ide_product.text, e_build.text, products)
  if result != e_ide_product.text && result != e_build.text
    log.append("[Browse] Auto-detected build: #{result}\n")
  end
  result
}
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

# Preload installed plugins on main thread at startup
App.installed_plugins = nil
raw = e_plugins_dir.text
if raw && !raw.empty?
  dir = GuiSettings.expand_tilde(raw) || raw
  App.installed_plugins = JBUpdater::PluginMeta.scan_dir(dir) rescue nil
end

# Populate installed tab model with startup data
inst = App.installed_plugins
if inst && inst.size > 0
  App.installed_plugins_arr.each_with_index { |_, i| App.installed_model.try &.row_inserted(i) }
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
