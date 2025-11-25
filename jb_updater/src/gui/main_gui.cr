# src/gui/main_gui.cr

require "uing"
require "../jb_updater"
require "../jb_updater/detect_products"

# ---- Messages passed from worker to UI ----
struct LineMsg
  getter text : String

  def initialize(@text : String); end
end

# Overall progress (all plugins)
struct OverallPercentMsg
  getter percent : Int32

  def initialize(@percent : Int32); end
end

# Per-plugin progress (current download)
struct PluginPercentMsg
  getter percent : Int32

  def initialize(@percent : Int32); end
end

alias Msg = LineMsg | OverallPercentMsg | PluginPercentMsg

# Include Nil to match Crystal 1.17.1 select/closed-channel behavior
CHANNEL = Channel(Msg | Nil).new(capacity: 1024)

# Small helpers
def send_line(text : String)
  CHANNEL.send(LineMsg.new(text))
end

def send_overall_percent(pct : Int32)
  CHANNEL.send(OverallPercentMsg.new(pct))
end

def send_plugin_percent(pct : Int32)
  CHANNEL.send(PluginPercentMsg.new(pct))
end

# ---- Global access to log/progress widgets ----
module App
  @@log : UIng::MultilineEntry?
  @@overall_progress : UIng::ProgressBar?
  @@plugin_progress : UIng::ProgressBar?
  @@buttons : Array(UIng::Button) = [] of UIng::Button

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
    @@log.not_nil!
  end

  def self.overall_progress : UIng::ProgressBar
    @@overall_progress.not_nil!
  end

  def self.plugin_progress : UIng::ProgressBar
    @@plugin_progress.not_nil!
  end

  # Enable/disable all tracked buttons (must be called on UI thread)
  def self.set_busy(busy : Bool)
    enabled = !busy
    @@buttons.each do |btn|
      if enabled
        btn.enable
      else
        btn.disable
      end
    end
  end
end

# ---- Timer callback: drain CHANNEL on UI thread via select ----
fun pump_cb(_data : Void*) : LibC::Int
  max_per_tick = 500
  count = 0

  begin
    loop do
      break if count >= max_per_tick

      handled = false

      select
      when raw = CHANNEL.receive
        handled = true

        # Runtime may yield nil when channel is closed; just stop reading
        next unless raw

        msg = raw.not_nil!
        case msg
        when LineMsg
          text = msg.text

          # Re-enable buttons on plugin update completion or explicit run-done marker
          if text.includes?("✔ Done. Start the IDE to load updated plugins.") ||
             text == "[GUI] RUN DONE"
            App.set_busy(false)
          end

          App.log.append(text + "\n")
        when OverallPercentMsg
          App.overall_progress.value = msg.percent
        when PluginPercentMsg
          App.plugin_progress.value = msg.percent
        end

        count += 1
      else
        # no message ready right now; leave loop
        break
      end
    end
  rescue ex : TypeCastError
    # Defensive: if select/receive hit the Nil-cast bug, log and re-enable buttons
    send_line("[GUI] pump_cb ERROR: #{ex.message}")
    App.set_busy(false)
  end

  1
end

# ---- Helpers ---------------------------------------------------------
private def expand_tilde(text : String?) : String?
  return nil unless text
  return nil if text.empty?
  JBUpdater::Utils.expand_tilde(text)
end

def new_run_header(action : String, args : Array(String))
  send_line("")
  send_line("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  send_line("#{action} at #{Time.local}")
  send_line("Command: ./jb_updater #{args.join(" ")}")
  send_line("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
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

  plugins_dir = expand_tilde(e_plugins_dir.text)
  build = e_build.text
  product = e_product.text
  install_ids = e_install_ids.text

  args += ["--plugins-dir", plugins_dir] if plugins_dir && !plugins_dir.empty?
  args += ["--build", build] if build && !build.empty?
  args += ["--product", product] if product && !product.empty?
  args += ["--install-plugin", install_ids] if install_ids && !install_ids.empty?

  case combo_arch.selected
  when 1
    args += ["--arch", "arm"]
  when 2
    args += ["--arch", "intel"]
  end

  args << "--dry-run" if chk_dry.checked?
  args << "--list" if chk_list.checked?
  args
end

private def jb_exe_path : String
  here = File.dirname(Process.executable_path.not_nil!)
  cand = File.expand_path(File.join(here, "jb_updater"))
  return cand if File.executable?(cand)
  cand2 = "./jb_updater"
  return cand2 if File.executable?(cand2)
  ENV["JB_UPDATER"]? || "jb_updater"
end

# ---- CLI execution: worker thread reads pipe, sends to CHANNEL ----
private def run_cli(args : Array(String)) : Nil
  r, w = IO.pipe

  # Disable buttons for the duration of this run (UI thread)
  App.set_busy(true)

  exe = jb_exe_path
  send_line("[GUI] spawn: #{exe} #{args.join(" ")}")

  begin
    p = Process.new(exe, args: args, output: w, error: w)
  rescue ex
    send_line("[GUI] ERROR: failed to spawn: #{ex.message}")
    w.close
    r.close
    App.set_busy(false)
    return
  end
  w.close
  send_line("[GUI] pid=#{p.pid}")

  # pattern for "[n/total]" progress lines from CLI
  step_re = /\[(\d+)\/(\d+)\]/
  # ASCII progress bar line: "[#####     ] 37.5%"
  bar_re = /^\[[# ]+\]\s+(\d+(?:\.\d+)?)%$/
  # fallback: any "NN%" in a line
  percent_re = /(\d+(?:\.\d+)?)%/

  Thread.new do
    begin
      buf = Bytes.new(4096)
      partial = ""

      while (n = r.read(buf)) > 0
        chunk = String.new(buf[0, n])
        partial += chunk

        last_nl = partial.rindex('\n') || partial.rindex('\r')
        if last_nl
          lines_part = partial[0..last_nl]
          partial = partial[(last_nl + 1)..] || ""

          lines_part.each_line do |orig_line|
            line = orig_line.chomp

            # 1) ASCII per-plugin progress: "[#######    ] 88.4%"
            if m = bar_re.match(line)
              pct = m[1].to_f.round.to_i
              send_plugin_percent(pct.clamp(0, 100))
              next
            end

            # 2) Overall "[n/total]" plugin progress
            if m = step_re.match(line)
              cur = m[1].to_i
              total = m[2].to_i
              if total > 0
                pct = (cur.to_f / total * 100).round.to_i
                send_overall_percent(pct.clamp(0, 100))
              end
            end

            # 3) Fallback: any "NN%" in the line; treat as per-plugin progress
            if m = percent_re.match(line)
              pct = m[1].to_f.round.to_i
              send_plugin_percent(pct.clamp(0, 100))
            end

            send_line(line)
          end
        end
      end

      send_line(partial) unless partial.empty?
    rescue ex
      send_line("[GUI] worker ERROR: #{ex.class}: #{ex.message}")
      ex.backtrace.each { |f| send_line("  #{f}") }
    ensure
      r.close
      status = p.wait
      send_line("[GUI] exited #{status.exit_code} (success=#{status.success?})")
      send_overall_percent(status.success? ? 100 : 0)
      send_plugin_percent(0)
      # For non-plugin cases (IDE list/upgrade), this marker will cause buttons to re-enable
      send_line("[GUI] RUN DONE")
    end
  end
end

# ---- UI --------------------------------------------------------------
UIng.init do
  window = UIng::Window.new("JB Updater", 880, 600)
  window.on_closing { UIng.quit; true }

  root = UIng::Box.new(:vertical)
  root.padded = true
  window.set_child(root)

  tabs = UIng::Tab.new
  root.append(tabs, true)

  # Shared log and two progress bars
  log = UIng::MultilineEntry.new
  log.read_only = true

  overall_label = UIng::Label.new("Overall:")
  overall_bar = UIng::ProgressBar.new

  plugin_label = UIng::Label.new("Current plugin:")
  plugin_bar = UIng::ProgressBar.new

  pb_box = UIng::Box.new(:vertical)
  pb_box.padded = true

  row1 = UIng::Box.new(:horizontal)
  row1.append(overall_label, false)
  row1.append(overall_bar, true)

  row2 = UIng::Box.new(:horizontal)
  row2.append(plugin_label, false)
  row2.append(plugin_bar, true)

  pb_box.append(row1, false)
  pb_box.append(row2, false)

  root.append(pb_box, false)
  root.append(log, true)

  # --- Plugins tab ----------------------------------------------------
  plugins = UIng::Box.new(:vertical)
  plugins.padded = true
  form = UIng::Form.new
  form.padded = true

  e_plugins_dir = UIng::Entry.new
  e_build = UIng::Entry.new
  e_product = UIng::Entry.new
  e_install_ids = UIng::Entry.new

  combo_arch = UIng::Combobox.new
  ["Auto", "arm", "intel"].each { |s| combo_arch.append s }
  combo_arch.selected = 0

  chk_dry = UIng::Checkbox.new("Dry run")
  dummy_chk = UIng::Checkbox.new("")

  combo_products = UIng::Combobox.new
  detected = JBUpdater::DetectProducts.all

  combo_products.append("Manual / Custom")
  detected.each do |prod|
    combo_products.append("#{prod.name} (#{prod.code})")
  end
  combo_products.selected = 0

  form.append("Detected product", combo_products, false)
  form.append("Plugins dir", e_plugins_dir, false)
  form.append("Build", e_build, false)
  form.append("Product (config folder, e.g. RubyMine2025.2)", e_product, false)
  form.append("Install IDs (comma-separated)", e_install_ids, false)
  form.append("Arch (plugins)", combo_arch, false)

  if detected.empty?
    send_line("No JetBrains IDEs detected automatically. Please enter plugins dir or IDE path manually.")
  end

  # --- IDE tab widgets ---
  ide = UIng::Box.new(:vertical)
  ide.padded = true
  ide_form = UIng::Form.new
  ide_form.padded = true

  e_ide_product = UIng::Entry.new
  e_ide_path = UIng::Entry.new
  chk_brew = UIng::Checkbox.new("Patch Homebrew cask (macOS)")

  ide_form.append("IDE code or name (e.g., WS, RM, WebStorm2025.2)", e_ide_product, false)
  ide_form.append("IDE Path (.app or install dir)", e_ide_path, false)

  btn_list_releases = UIng::Button.new("List releases")
  btn_upgrade = UIng::Button.new("Upgrade IDE")

  ide.append(ide_form, false)
  ide.append(chk_brew, false)
  ide.append(btn_list_releases, false)
  ide.append(btn_upgrade, false)
  tabs.append("IDE Upgrade", ide)

  # Wire detected products combobox
  combo_products.on_selected do
    idx = combo_products.selected
    if idx <= 0
      send_line("[GUI] Product selection: manual/custom")
      next
    end

    prod = detected[idx - 1]
    send_line("[GUI] Selected product: #{prod.name} (#{prod.code})")

    if prod.plugins_dir
      e_plugins_dir.text = prod.plugins_dir.not_nil!
    end
    e_product.text = prod.name
    e_ide_product.text = prod.code
    if path = prod.ide_path
      e_ide_path.text = path
    end
  end

  # Detect-from-Product button
  detect_row = UIng::Box.new(:horizontal)
  btn_detect = UIng::Button.new("Detect from Product")
  detect_row.append(btn_detect, false)

  # Action buttons
  row = UIng::Box.new(:horizontal)
  btn_list = UIng::Button.new("List installed")
  btn_install = UIng::Button.new("Install by IDs")
  btn_update = UIng::Button.new("Update all")
  [btn_list, btn_install, btn_update].each { |b| row.append(b, false) }

  plugins.append(form, false)
  plugins.append(detect_row, false)
  plugins.append(chk_dry, false)
  plugins.append(row, false)
  tabs.append("Plugins", plugins)

  # Register widgets + buttons with App
  all_buttons = [] of UIng::Button
  all_buttons.concat([btn_list, btn_install, btn_update])
  all_buttons.concat([btn_list_releases, btn_upgrade])
  App.set_widgets(log, overall_bar, plugin_bar, all_buttons)

  # Start timer to drain CHANNEL via pump_cb
  UIng::LibUI.timer(50, ->pump_cb, Pointer(Void).null)

  send_line("JB Updater GUI ready. Select a detected IDE or enter paths manually.")

  # ---- Wire buttons: Plugins tab ------------------------------------
  btn_detect.on_clicked do
    product = e_product.text
    if product.nil? || product.empty?
      send_line("ERROR: Enter Product (e.g., RubyMine2025.2) before Detect.")
      next
    end

    begin
      resolved = JBUpdater::Utils.resolve_product_folder(product)
      path = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
      e_plugins_dir.text = path
      send_line("Detected plugins dir: #{path}")
    rescue ex
      send_line("ERROR: #{ex.message}")
    end
  end

  btn_list.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      send_line("ERROR: Plugins dir is required for List.")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      dummy_chk
    ) + ["--list"]

    App.overall_progress.value = 0
    App.plugin_progress.value = 0
    new_run_header("List installed plugins", args)
    run_cli(args)
  end

  btn_install.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      send_line("ERROR: Plugins dir is required for Install.")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      dummy_chk
    )
    send_line("DEBUG: args for jb_updater: #{args.join(" ")}")
    App.overall_progress.value = 0
    App.plugin_progress.value = 0
    new_run_header("Install plugins", args)
    run_cli(args)
  end

  btn_update.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      send_line("ERROR: Plugins dir is required for Update.")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      dummy_chk
    )
    send_line("DEBUG: args for jb_updater: #{args.join(" ")}")
    App.overall_progress.value = 0
    App.plugin_progress.value = 0
    new_run_header("Update plugins", args)
    run_cli(args)
  end

  # ---- Wire buttons: IDE tab ----------------------------------------
  btn_list_releases.on_clicked do
    product = e_ide_product.text
    if product.nil? || product.empty?
      send_line("ERROR: IDE code is required for List releases (e.g., WS, RM).")
      next
    end

    args = ["--list-ide-releases", "--product", product]
    send_line("DEBUG: args for jb_updater (IDE releases): #{args.join(" ")}")
    App.overall_progress.value = 0
    App.plugin_progress.value = 0
    new_run_header("List IDE releases", args)
    run_cli(args)
  end

  btn_upgrade.on_clicked do
    args = ["--upgrade-ide"]

    ide_product = e_ide_product.text
    ide_path = e_ide_path.text

    args += ["--product", ide_product] if ide_product && !ide_product.empty?
    args += ["--ide-path", ide_path] if ide_path && !ide_path.empty?
    args << "--brew" if chk_brew.checked?

    send_line("DEBUG: args for jb_updater (IDE upgrade): #{args.join(" ")}")
    App.overall_progress.value = 0
    App.plugin_progress.value = 0
    new_run_header("Upgrade IDE", args)
    run_cli(args)
  end

  window.show
  UIng.main
end
