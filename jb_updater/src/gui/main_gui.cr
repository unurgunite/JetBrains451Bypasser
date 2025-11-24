require "uing"

# ---- Small message pump to safely touch widgets on the UI thread ----
struct LineMsg
  getter text : String

  def initialize(@text : String)
  end
end

struct PercentMsg
  getter percent : Int32

  def initialize(@percent : Int32)
  end
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

  1 # non-zero to keep the timer running
end

# ---- Top-level helper methods (not inside UIng.init) ----------------
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

  plugins_dir = e_plugins_dir.text
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
  CHANNEL.send(LineMsg.new("DEBUG: run_cli starting"))

  r, w = IO.pipe
  CHANNEL.send(LineMsg.new("DEBUG: pipe created"))

  exe = "./jb_updater"
  CHANNEL.send(LineMsg.new("DEBUG: about to spawn #{exe} #{args.join(" ")}"))

  begin
    p = Process.new(exe, args: args, output: w, error: w)
  rescue ex
    CHANNEL.send(LineMsg.new("ERROR: failed to spawn #{exe}: #{ex.message}"))
    w.close
    r.close
    return
  end

  CHANNEL.send(LineMsg.new("DEBUG: process spawned, pid=#{p.pid}"))

  w.close
  CHANNEL.send(LineMsg.new("DEBUG: write-end closed"))

  Thread.new do
    CHANNEL.send(LineMsg.new("DEBUG: reader thread started"))
    begin
      buf = Bytes.new(4096)
      partial = ""
      percent_re = /(\d+(?:\.\d+)?)%/

      while (n = r.read(buf)) > 0
        CHANNEL.send(LineMsg.new("DEBUG: read #{n} bytes from pipe"))
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
      CHANNEL.send(LineMsg.new("Process exited with #{status.exit_code} (success=#{status.success?})"))
      CHANNEL.send(PercentMsg.new(status.success? ? 100 : 0))
    end
  end

  CHANNEL.send(LineMsg.new("DEBUG: run_cli returning to UI thread"))
end

# ---- UI --------------------------------------------------------------
UIng.init do
  window = UIng::Window.new("JB Updater", 880, 560)
  window.on_closing { UIng.quit; true }

  # Root layout: vertical box with tabs at top, global progress + log at bottom
  root = UIng::Box.new(:vertical)
  root.padded = true
  window.set_child(root)

  tabs = UIng::Tab.new
  root.append(tabs, true)

  # Global shared widgets
  log = UIng::MultilineEntry.new
  log.read_only = true
  progress = UIng::ProgressBar.new
  App.set_widgets(log, progress)

  root.append(progress, false)
  root.append(log, true)

  # Start a 50ms UI-thread pump to consume messages and update widgets
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
  chk_list = UIng::Checkbox.new("List plugins")

  form.append("Plugins dir", e_plugins_dir, false)
  form.append("Build", e_build, false)
  form.append("Product", e_product, false)
  form.append("Install IDs (comma-separated)", e_install_ids, false)
  form.append("Arch", combo_arch, false)

  row = UIng::Box.new(:horizontal)
  btn_list = UIng::Button.new("List")
  btn_install = UIng::Button.new("Install")
  btn_update = UIng::Button.new("Update")
  [btn_list, btn_install, btn_update].each { |b| row.append(b, false) }

  plugins.append(form, false)
  plugins.append(chk_dry, false)
  plugins.append(chk_list, false)
  plugins.append(row, false)
  tabs.append("Plugins", plugins)

  # --- IDE tab --------------------------------------------------------
  ide = UIng::Box.new(:vertical)
  ide.padded = true
  ide_form = UIng::Form.new
  ide_form.padded = true

  e_ide_product = UIng::Entry.new
  e_ide_path = UIng::Entry.new
  chk_brew = UIng::Checkbox.new("Patch Homebrew cask (macOS)")
  btn_upgrade = UIng::Button.new("Upgrade IDE")

  ide_form.append("Product (e.g., RubyMine or RubyMine2025.2)", e_ide_product, false)
  ide_form.append("IDE Path (.app or install dir)", e_ide_path, false)
  ide.append(ide_form, false)
  ide.append(chk_brew, false)
  ide.append(btn_upgrade, false)
  tabs.append("IDE Upgrade", ide)

  # ---- Wire buttons --------------------------------------------------
  btn_list.on_clicked do
    CHANNEL.send(LineMsg.new("DEBUG: List clicked"))

    text = e_plugins_dir.text
    if text.nil? || text.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for List."))
      next
    end

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      chk_list
    ) + ["--list"]

    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))

    run_cli(args)
  end

  btn_install.on_clicked do
    text = e_plugins_dir.text
    if text.nil? || text.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for Install."))
      next
    end

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      chk_list
    )
    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))

    run_cli(args)
  end

  btn_update.on_clicked do
    text = e_plugins_dir.text
    if text.nil? || text.empty?
      CHANNEL.send(LineMsg.new("ERROR: Plugins dir is required for Update."))
      next
    end

    args = build_args(
      e_plugins_dir,
      e_build,
      e_product,
      e_install_ids,
      combo_arch,
      chk_dry,
      chk_list
    )
    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater: #{args.join(" ")}"))

    run_cli(args)
  end

  btn_upgrade.on_clicked do
    args = ["--upgrade-ide"]

    ide_product = e_ide_product.text
    ide_path = e_ide_path.text

    args += ["--product", ide_product] if ide_product && !ide_product.empty?
    args += ["--ide-path", ide_path] if ide_path && !ide_path.empty?
    args << "--brew" if chk_brew.checked?

    CHANNEL.send(LineMsg.new("DEBUG: args for jb_updater (IDE): #{args.join(" ")}"))

    run_cli(args)
  end

  window.show
  UIng.main
end
