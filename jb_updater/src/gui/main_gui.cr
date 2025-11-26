require "uing"
require "../jb_updater"
require "../jb_updater/detect_products"
require "file_utils"

# ---- Global access to log/progress widgets ----
module App
  @@log : UIng::MultilineEntry?
  @@overall_progress : UIng::ProgressBar?
  @@plugin_progress : UIng::ProgressBar?
  @@buttons : Array(UIng::Button) = [] of UIng::Button
  @@busy : Bool = false
  @@shutting_down : Bool = false

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

  def self.busy? : Bool
    @@busy
  end

  def self.shutting_down? : Bool
    @@shutting_down
  end

  def self.mark_shutting_down
    @@shutting_down = true
  end

  # Called from UI thread: clear busy and enable all tracked buttons
  def self.debug_reenable
    return if @@shutting_down

    if @@log
      App.log.append("[GUI] debug_reenable(): forcing not busy and enabling buttons\n") rescue nil
    end

    @@busy = false
    @@buttons.each &.enable
  end

  # Enable/disable all tracked buttons (must be called on UI thread)
  def self.set_busy(busy : Bool)
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
      App.plugin_progress.value = 0
    end
  end
end

# ---- Helpers ---------------------------------------------------------
private def expand_tilde(text : String?) : String?
  return nil unless text
  return nil if text.empty?
  JBUpdater::Utils.expand_tilde(text)
end

def new_run_header(action : String, args : Array(String))
  UIng.queue_main do
    App.log.append("\n")
    App.log.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    App.log.append("#{action} at #{Time.local}\n")
    App.log.append("Command: ./jb_updater #{args.join(" ")}\n")
    App.log.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
  end
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
  when 1 then args += ["--arch", "arm"]
  when 2 then args += ["--arch", "intel"]
  end

  args << "--dry-run" if chk_dry.checked?
  args << "--list" if chk_list.checked?
  args
end

private def jb_exe_path : String
  here = File.dirname(Process.executable_path.not_nil!)
  cand = File.expand_path(File.join(here, "jb_updater"))
  cand2 = "./jb_updater"

  return cand if File::Info.executable?(cand)
  return cand2 if File::Info.executable?(cand2)
  ENV["JB_UPDATER"]? || "jb_updater"
end

# ---- CLI execution: spawn jb_updater, stream output, update UI via queue_main ----
private def run_cli(args : Array(String)) : Nil
  # Don’t start another job while one is in progress
  if App.busy?
    UIng.queue_main do
      next if App.shutting_down?
      App.log.append("[GUI] Ignoring request: updater already running\n")
    end
    return
  end

  exe = jb_exe_path

  # mark GUI as busy on UI thread
  UIng.queue_main do
    next if App.shutting_down?
    App.set_busy(true)
  end

  # log spawn line
  UIng.queue_main do
    next if App.shutting_down?
    App.log.append("[GUI] spawn: #{exe} #{args.join(" ")}\n")
  end

  # Create a pipe to read process output (stdout+stderr)
  r, w = IO.pipe

  begin
    p = Process.new(exe, args: args, output: w, error: w)
  rescue ex
    UIng.queue_main do
      next if App.shutting_down?
      App.log.append("[GUI] ERROR: failed to spawn: #{ex.message}\n")
      App.debug_reenable
    end
    w.close
    r.close
    return
  end
  w.close

  UIng.queue_main do
    next if App.shutting_down?
    App.log.append("[GUI] pid=#{p.pid}\n")
  end

  step_re = /\[(\d+)\/(\d+)\]/
  percent_re = /(\d+(?:\.\d+)?)%/

  # Numeric bar parser: "[####    ] 93.3%" (optional spaces)
  bar_re = /^\[[# ]+\]\s*(\d+(?:\.\d+)?)%\s*$/
  # Loose detector for "bar-like" lines
  bar_line_re = /^\[[# ]+\].*%\s*$/

  Thread.new do
    begin
      buf = Bytes.new(4096)
      partial = ""

      while (n = r.read(buf)) > 0
        chunk = String.new(buf[0, n])
        partial += chunk

        if last_nl = (partial.rindex('\n') || partial.rindex('\r'))
          lines_part = partial[0..last_nl]
          partial = partial[(last_nl + 1)..] || ""

          lines_part.each_line do |orig_line|
            line = orig_line.chomp("\n").chomp("\r")

            UIng.queue_main do
              next if App.shutting_down?

              is_bar_line = !!bar_line_re.match(line)

              if m = bar_re.match(line)
                pct = m[1].to_f.round.to_i
                App.plugin_progress.value = pct.clamp(0, 100)
              elsif m = step_re.match(line)
                cur = m[1].to_i
                total = m[2].to_i
                if total > 0
                  pct = (cur.to_f / total * 100).round.to_i
                  App.overall_progress.value = pct.clamp(0, 100)
                end
              elsif m = percent_re.match(line)
                pct = m[1].to_f.round.to_i
                App.plugin_progress.value = pct.clamp(0, 100)
              end

              App.log.append(line + "\n") if !is_bar_line && !line.empty?
            end
          end
        end
      end

      unless partial.empty?
        UIng.queue_main do
          next if App.shutting_down?

          partial.each_line do |orig_line|
            line = orig_line.chomp("\n").chomp("\r")
            next if line.empty?

            is_bar_line = !!bar_line_re.match(line)

            if m = bar_re.match(line)
              pct = m[1].to_f.round.to_i
              App.plugin_progress.value = pct.clamp(0, 100)
            end

            App.log.append(line + "\n") unless is_bar_line
          end
        end
      end
    rescue ex
      UIng.queue_main do
        next if App.shutting_down?
        App.log.append("[GUI] worker ERROR: #{ex.class}: #{ex.message}\n")
        ex.backtrace.each { |f| App.log.append("  #{f}\n") }
      end
    ensure
      # Close read end of the pipe
      r.close

      # From the GUI's point of view, output is done → job finished.
      UIng.queue_main do
        begin
          next if App.shutting_down?
          App.log.append("[GUI] run_cli: output stream finished; re-enabling UI\n") rescue nil
          App.debug_reenable
        rescue
        end
      end
    end
  end
end

# ---- UI --------------------------------------------------------------
UIng.init do
  window = UIng::Window.new("JB Updater", 880, 600)
  window.on_closing do
    App.mark_shutting_down
    UIng.quit
    true
  end

  root = UIng::Box.new(:vertical)
  root.padded = true
  window.set_child(root)

  tabs = UIng::Tab.new
  root.append(tabs, true)

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

  # Global actions row: Clear console, Remove cache, Debug
  actions_row = UIng::Box.new(:horizontal)
  btn_clear_log = UIng::Button.new("Clear console")
  btn_remove_cache = UIng::Button.new("Remove *.bak* plugin backups")
  debug_btn = UIng::Button.new("DEBUG: Re-enable UI")

  actions_row.append(btn_clear_log, false)
  actions_row.append(btn_remove_cache, false)
  actions_row.append(debug_btn, false)
  root.append(actions_row, false)

  # Clear console
  btn_clear_log.on_clicked do
    UIng.queue_main do
      log.text = ""
      log.append("Console cleared at #{Time.local}\n")
    end
  end

  # DEBUG re-enable
  debug_btn.on_clicked do
    UIng.queue_main { App.debug_reenable }
  end

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
    log.append("No JetBrains IDEs detected automatically. Please enter plugins dir or IDE path manually.\n")
  end

  # --- IDE tab widgets ------------------------------------------------
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

  combo_products.on_selected do
    idx = combo_products.selected
    if idx <= 0
      log.append("[GUI] Product selection: manual/custom\n")
      next
    end

    prod = detected[idx - 1]
    log.append("[GUI] Selected product: #{prod.name} (#{prod.code})\n")

    if prod.plugins_dir
      e_plugins_dir.text = prod.plugins_dir.not_nil!
    end
    e_product.text = prod.name
    e_ide_product.text = prod.code
    if path = prod.ide_path
      e_ide_path.text = path
    end
  end

  detect_row = UIng::Box.new(:horizontal)
  btn_detect = UIng::Button.new("Detect from Product")
  detect_row.append(btn_detect, false)

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

  all_buttons = [] of UIng::Button
  all_buttons.concat([btn_list, btn_install, btn_update])
  all_buttons.concat([btn_list_releases, btn_upgrade])
  App.set_widgets(log, overall_bar, plugin_bar, all_buttons)

  log.append("JB Updater GUI ready. Select a detected IDE or enter paths manually.\n")

  # ---- Wire buttons: Remove cache ------------------------------------
  btn_remove_cache.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for Remove cache.\n")
      next
    end

    plugins_dir = expand_tilde(raw) || raw
    unless Dir.exists?(plugins_dir)
      log.append("ERROR: Plugins dir '#{plugins_dir}' does not exist.\n")
      next
    end

    begin
      removed = 0
      Dir.each_child(plugins_dir) do |entry|
        # treat anything containing ".bak" as a backup; or tighten this if you want
        if entry.includes?(".bak")
          path = File.join(plugins_dir, entry)
          FileUtils.rm_rf(path)
          removed += 1
          log.append("Removed backup: #{path}\n")
        end
      end

      if removed == 0
        log.append("No *.bak* backup entries found under #{plugins_dir}\n")
      else
        log.append("Removed #{removed} backup entr#{removed == 1 ? "y" : "ies"} under #{plugins_dir}\n")
      end
    rescue ex
      log.append("ERROR while removing cache: #{ex.class}: #{ex.message}\n")
    end
  end

  # ---- Wire buttons: Plugins tab actions -----------------------------
  btn_detect.on_clicked do
    product = e_product.text
    if product.nil? || product.empty?
      log.append("ERROR: Enter Product (e.g., RubyMine2025.2) before Detect.\n")
      next
    end

    begin
      resolved = JBUpdater::Utils.resolve_product_folder(product)
      path = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
      e_plugins_dir.text = path
      log.append("Detected plugins dir: #{path}\n")
    rescue ex
      log.append("ERROR: #{ex.message}\n")
    end
  end

  btn_list.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for List.\n")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, dummy_chk) + ["--list"]
    new_run_header("List installed plugins", args)
    run_cli(args)
  end

  btn_install.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for Install.\n")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, dummy_chk)
    log.append("DEBUG: args for jb_updater: #{args.join(" ")}\n")
    new_run_header("Install plugins", args)
    run_cli(args)
  end

  btn_update.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      log.append("ERROR: Plugins dir is required for Update.\n")
      next
    end

    plugins_dir = expand_tilde(raw)
    e_plugins_dir.text = plugins_dir if plugins_dir

    args = build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, dummy_chk)
    log.append("DEBUG: args for jb_updater: #{args.join(" ")}\n")
    new_run_header("Update plugins", args)
    run_cli(args)
  end

  # ---- Wire buttons: IDE tab ----------------------------------------
  btn_list_releases.on_clicked do
    product = e_ide_product.text
    if product.nil? || product.empty?
      log.append("ERROR: IDE code is required for List releases (e.g., WS, RM).\n")
      next
    end

    args = ["--list-ide-releases", "--product", product]
    log.append("DEBUG: args for jb_updater (IDE releases): #{args.join(" ")}\n")
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

    log.append("DEBUG: args for jb_updater (IDE upgrade): #{args.join(" ")}\n")
    new_run_header("Upgrade IDE", args)
    run_cli(args)
  end

  window.show
  UIng.main
end
