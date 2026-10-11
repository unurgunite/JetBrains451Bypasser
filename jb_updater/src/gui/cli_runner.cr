# Builds CLI argument arrays and runs `jb_updater` logic in-process.
#
# Everything runs on a background thread exactly like the legacy
# subprocess path, but avoids `Process.run` from a spawned thread,
# which deadlocks under Crystal 1.21 (spawning is main-context only).
module CliRunner
  # Appends a formatted section header to the log console.
  def self.new_run_header(action : String, args : Array(String))
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
  private def self.arch_args(combo_arch : UIng::Combobox) : Array(String)
    case combo_arch.selected
    when 1 then ["--arch", "arm"]
    when 2 then ["--arch", "intel"]
    else        [] of String
    end
  end

  private def self.add_opt(args : Array(String), flag : String, value : String?)
    args.concat([flag, value]) if value && !value.empty?
  end

  def self.build_args(
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

    add_opt(args, "--plugins-dir", GuiSettings.expand_tilde(e_plugins_dir.text))
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
  # `Log.*` output and HTTP progress already route to the GUI console
  # and progress bars via the listeners installed at startup.
  #
  # @param args [Array(String)] CLI arguments
  def self.run(args : Array(String)) : Nil
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
end
