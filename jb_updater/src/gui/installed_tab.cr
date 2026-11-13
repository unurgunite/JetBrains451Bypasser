# Installed tab: scan, update, and uninstall local plugins.
module InstalledTab
  # Builds the tab content and wires all handlers.
  #
  # @param ctx [GuiCtx] Shared widgets and state
  # @return [UIng::Box] Tab root
  def self.build(ctx : GuiCtx) : UIng::Box
    status_label = ctx.status_label
    e_plugins_dir = ctx.e_plugins_dir
    e_build = ctx.e_build
    e_product = ctx.e_product
    e_install_ids = ctx.e_install_ids
    combo_arch = ctx.combo_arch
    combo_products = ctx.combo_products
    chk_dry = ctx.chk_dry

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

    btn_scan_installed.on_clicked do
      dir = GuiSettings.expand_tilde(e_plugins_dir.text) || e_plugins_dir.text || ""
      if dir.empty?
        installed_status.text = "Set Plugins Directory first"
        next
      end
      scanned = JBUpdater::PluginMeta.scan_dir(dir) rescue nil
      if scanned
        GuiTabHelpers.apply_installed_scan(scanned)
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

    btn_update.on_clicked do
      UIng.queue_main do
        if App.busy?
          status_label.text = "Already running… please wait"
          next
        end
        raw = e_plugins_dir.text
        if raw.nil? || raw.empty?
          ctx.log.append("ERROR: Plugins dir is required for Update plugins.\n")
          status_label.text = "Error: missing plugins dir"
          next
        end
        plugins_dir = GuiSettings.expand_tilde(raw)
        e_plugins_dir.text = plugins_dir if plugins_dir
        args = CliRunner.build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""), include_install: false)
        CliRunner.new_run_header("Update plugins", args)
        CliRunner.run(args)
        GuiTabHelpers.save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
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
          ctx.log.append("ERROR: Plugins dir is required for Update selected plugins.\n")
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
        plugins_dir = GuiSettings.expand_tilde(raw)
        e_plugins_dir.text = plugins_dir if plugins_dir
        args = CliRunner.build_args(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, chk_dry, UIng::Checkbox.new(""), include_install: false)
        args << "--install-plugin" << ids.join(",")
        CliRunner.new_run_header("Update selected plugins", args)
        CliRunner.run(args)
        GuiTabHelpers.save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
      end
    end

    installed_tab
  end
end
