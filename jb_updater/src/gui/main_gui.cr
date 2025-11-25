require "uing"
require "../jb_updater"
require "../jb_updater/detect_products"

# ---- Small message pump to safely touch widgets on the UI thread ----
struct LineMsg
  getter text : String

  def initialize(@text : String); end
end

struct PercentMsg
  getter percent : Int32

  def initialize(@percent : Int32); end
end

alias Msg = LineMsg | PercentMsg
CHANNEL = Channel(Msg).new(capacity: 1024)

# Keep references to widgets without capturing closures in C callbacks
module App
  @@log : UIng::MultilineEntry?
  @@progress : UIng::ProgressBar?

  def self.set_widgets(log : UIng::MultilineEntry, progress : UIng::ProgressBar)
    @@log = log
    @@progress = progress
  end

  def self.log : UIng::MultilineEntry
    @@log.not_nil!
  end

  def self.progress : UIng::ProgressBar
    @@progress.not_nil!
  end
end

# Timer callback (must be a top-level function; no captures)
fun pump_cb(data : Void*) : LibC::Int
  loop do
    handled = false

    select
    when msg = CHANNEL.receive
      handled = true
      case msg
      when LineMsg
        App.log.append(msg.text + "\n")
      when PercentMsg
        App.progress.value = msg.percent
      end
    else
      # nothing to read right now
    end

    break unless handled
  end
  1
end

# ---- Helpers ---------------------------------------------------------
private def expand_tilde(text : String?) : String?
  return nil unless text
  return nil if text.empty?
  JBUpdater::Utils.expand_tilde(text)
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

private def run_cli(args : Array(String)) : Nil
  CHANNEL.send(LineMsg.new("[GUI] run_cli starting"))

  r, w = IO.pipe
  CHANNEL.send(LineMsg.new("[GUI] pipe created"))

  exe = "./jb_updater"
  CHANNEL.send(LineMsg.new("[GUI] about to spawn #{exe} #{args.join(" ")}"))

  begin
    p = Process.new(exe, args: args, output: w, error: w)
  rescue ex
    CHANNEL.send(LineMsg.new("[GUI] ERROR: failed to spawn #{exe}: #{ex.message}"))
    w.close
    r.close
    return
  end

  CHANNEL.send(LineMsg.new("[GUI] process spawned, pid=#{p.pid}"))

  w.close
  CHANNEL.send(LineMsg.new("[GUI] write-end closed"))

  Thread.new do
    CHANNEL.send(LineMsg.new("[GUI] reader thread started"))
    begin
      buf = Bytes.new(4096)
      partial = ""
      percent_re = /(\d+(?:\.\d+)?)%/

      while (n = r.read(buf)) > 0
        CHANNEL.send(LineMsg.new("[GUI] read #{n} bytes from pipe"))
        chunk = String.new(buf[0, n])
        partial += chunk

        if m = percent_re.match(chunk)
          pct = m[1].to_f.round.to_i
          CHANNEL.send(PercentMsg.new(pct))
        end

        loop do
          newline_index = partial.index('\n')
          carriage_index = partial.index('\r')

          delim_index =
            if newline_index && carriage_index
              {newline_index, carriage_index}.min
            elsif newline_index
              newline_index
            else
              carriage_index
            end

          break unless delim_index

          line = partial[0, delim_index]
          partial = partial[delim_index + 1, partial.bytesize - delim_index - 1] || ""
          CHANNEL.send(LineMsg.new(line))
        end
      end

      unless partial.empty?
        CHANNEL.send(LineMsg.new(partial))
      end
    ensure
      r.close
      status = p.wait
      CHANNEL.send(LineMsg.new("[GUI] Process exited with #{status.exit_code} (success=#{status.success?})"))
      CHANNEL.send(PercentMsg.new(status.success? ? 100 : 0))
    end
  end

  CHANNEL.send(LineMsg.new("[GUI] run_cli returning to UI thread"))
end

# ---- UI --------------------------------------------------------------
UIng.init do
  window = UIng::Window.new("JB Updater", 880, 560)
  window.on_closing { UIng.quit; true }

  root = UIng::Box.new(:vertical)
  root.padded = true
  window.set_child(root)

  tabs = UIng::Tab.new
  root.append(tabs, true)

  # Shared log/progress
  log = UIng::MultilineEntry.new
  log.read_only = true
  progress = UIng::ProgressBar.new
  App.set_widgets(log, progress)

  root.append(progress, false)
  root.append(log, true)

  CHANNEL.send(LineMsg.new("JB Updater GUI ready. Select a detected IDE or enter paths manually."))

  UIng::LibUI.timer(50, ->pump_cb, Pointer(Void).null)

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
  dummy_chk = UIng::Checkbox.new("") # never shown; only passed to build_args

  # Detected products combobox
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
    CHANNEL.send(LineMsg.new("No JetBrains IDEs detected automatically. Please enter plugins dir or IDE path manually."))
  end

  # IDE tab widgets must be defined before we use them in the combo_products handler
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

  # Now wire the detected products combobox, which can touch e_ide_product/e_ide_path
  combo_products.on_selected do
    idx = combo_products.selected
    if idx <= 0
      CHANNEL.send(LineMsg.new("[GUI] Product selection: manual/custom"))
      next
    end

    prod = detected[idx - 1]
    CHANNEL.send(LineMsg.new("[GUI] Selected product: #{prod.name} (#{prod.code})"))

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

  # ---- Wire buttons: Plugins tab ------------------------------------
  btn_detect.on_clicked do
    product = e_product.text
    if product.nil? || product.empty?
      CHANNEL.send(LineMsg.new("ERROR: Enter Product (e.g., RubyMine2025.2) before Detect."))
      next
    end

    begin
      resolved = JBUpdater::Utils.resolve_product_folder(product)
      path = JBUpdater::Utils.expand_jetbrains_plugins_dir(resolved)
      e_plugins_dir.text = path
      CHANNEL.send(LineMsg.new("Detected plugins dir: #{path}"))
    rescue ex
      CHANNEL.send(LineMsg.new("ERROR: #{ex.message}"))
    end
  end

  btn_list.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for List."))
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

    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))
    run_cli(args)
  end

  btn_install.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for Install."))
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
    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))
    run_cli(args)
  end

  btn_update.on_clicked do
    raw = e_plugins_dir.text
    if raw.nil? || raw.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for Update."))
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
    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))
    run_cli(args)
  end

  # ---- Wire buttons: IDE tab ----------------------------------------
  btn_list_releases.on_clicked do
    product = e_ide_product.text
    if product.nil? || product.empty?
      CHANNEL.send(LineMsg.new("ERROR: IDE code is required for List releases (e.g., WS, RM)."))
      next
    end

    args = ["--list-ide-releases", "--product", product]
    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater (IDE releases): #{args.join(" ")}"))
    run_cli(args)
  end

  btn_upgrade.on_clicked do
    args = ["--upgrade-ide"]

    ide_product = e_ide_product.text
    ide_path = e_ide_path.text

    args += ["--product", ide_product] if ide_product && !ide_product.empty?
    args += ["--ide-path", ide_path] if ide_path && !ide_path.empty?
    args << "--brew" if chk_brew.checked?

    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater (IDE upgrade): #{args.join(" ")}"))
    run_cli(args)
  end

  window.show
  UIng.main
end
