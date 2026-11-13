# Helpers shared by GUI tabs: background install queue, settings
# persistence, and IDE badge updates.
module GuiTabHelpers
  def self.queue_install(xml_id : String, plugins_dir : String, build : String)
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
  def self.save_plugins_settings(
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
    GuiSettings.save(data)
  end

  # Saves IDE tab UI field values to config.
  def self.save_ide_settings(
    e_ide_product : UIng::Entry,
    e_ide_path : UIng::Entry,
    chk_brew : UIng::Checkbox,
  )
    data = {} of String => String
    data["ide_product"] = e_ide_product.text || ""
    data["ide_path"] = e_ide_path.text || ""
    data["brew"] = chk_brew.checked?.to_s
    GuiSettings.save(data)
  end

  # Restores Plugins tab field values from saved config.
  def self.apply_plugins_settings(
    e_plugins_dir : UIng::Entry,
    e_build : UIng::Entry,
    e_product : UIng::Entry,
    e_install_ids : UIng::Entry,
    combo_arch : UIng::Combobox,
    combo_products : UIng::Combobox,
    chk_dry : UIng::Checkbox,
    log : UIng::MultilineEntry,
  )
    config = GuiSettings.load
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
  def self.update_ide_badge(e_product : UIng::Entry, e_build : UIng::Entry) : Nil
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
  def self.apply_ide_settings(
    e_ide_product : UIng::Entry,
    e_ide_path : UIng::Entry,
    chk_brew : UIng::Checkbox,
  )
    config = GuiSettings.load
    val = config.fetch("ide_product", "")
    e_ide_product.text = val =~ /\A[A-Z]+-\d/ ? val : ""
    e_ide_path.text = config.fetch("ide_path", "")
    if config.fetch("brew", "") == "true"
      chk_brew.checked = true
    end
  end

  # Applies a fresh PluginMeta scan to the Installed tab table (UI thread).
  def self.apply_installed_scan(scanned : Hash(String, JBUpdater::PluginMeta)) : Nil
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

  {% if flag?(:darwin) %}
    def self.setup_icon_and_keys
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
end
