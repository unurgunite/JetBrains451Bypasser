# Main (Plugins) tab: product detection, configuration, bulk actions.
module MainTab
  # Builds the tab content. Shared widgets are created by the caller
  # and passed via *ctx*; this method wires the tab-specific handlers.
  #
  # @param ctx [GuiCtx] Shared widgets and state
  # @return [UIng::Box] Tab root
  def self.build(ctx : GuiCtx) : UIng::Box
    log = ctx.log
    status_label = ctx.status_label
    e_plugins_dir = ctx.e_plugins_dir
    e_build = ctx.e_build
    e_product = ctx.e_product
    e_install_ids = ctx.e_install_ids
    combo_arch = ctx.combo_arch
    combo_products = ctx.combo_products
    chk_dry = ctx.chk_dry
    e_ide_product = ctx.e_ide_product
    detected = ctx.detected

    plugins_tab = UIng::Box.new(:vertical)
    plugins_tab.padded = true

    prod_group = UIng::Group.new("Product Detection", margined: true)
    prod_form = UIng::Form.new
    prod_form.padded = true
    prod_form.append("IDE / Product", combo_products, false)
    prod_group.child = prod_form
    plugins_tab.append(prod_group, false)

    config_group = UIng::Group.new("Configuration", margined: true)
    config_form = UIng::Form.new
    config_form.padded = true
    config_form.append("Plugins dir", e_plugins_dir, true)
    config_form.append("Build", e_build, false)
    config_form.append("Product", e_product, false)
    config_form.append("Arch", combo_arch, false)
    config_group.child = config_form
    plugins_tab.append(config_group, false)

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
            GuiTabHelpers.save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
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
    btn_update = UIng::Button.new("Update all")
    btn_update_selected = UIng::Button.new("Update selected")

    main_actions.append(btn_list, false)
    batch_group.child = main_actions
    btn_group.append(batch_group, false)

    plugins_tab.append(btn_group, false)

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
            ctx.e_ide_path.text = path
          end

          status_label.text = "Selected: #{prod.name}"
          GuiTabHelpers.update_ide_badge(e_product, e_build)
          GuiTabHelpers.save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
        else
          status_label.text = "Product selection: manual/custom"
          GuiTabHelpers.update_ide_badge(e_product, e_build)
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
        plugins_dir = GuiSettings.expand_tilde(raw) || raw
        e_plugins_dir.text = plugins_dir
        CliRunner.new_run_header("List installed plugins", ["--list", "--plugins-dir", plugins_dir])
        App.busy = true
        Thread.new do
          scanned = JBUpdater::PluginMeta.scan_dir(plugins_dir)
          UIng.queue_main do
            next if App.shutting_down?
            GuiTabHelpers.apply_installed_scan(scanned)
            msg = "Found #{scanned.size} installed plugins"
            ctx.status_label.text = msg
            log.append("[CLI] #{msg}\n")
            ctx.tabs.selected = 2
            App.busy = false
            App.debug_reenable
          end
        rescue ex
          UIng.queue_main do
            next if App.shutting_down?
            log.append("[CLI] ERROR: #{ex.message}\n")
            status_label.text = "Error: #{ex.message}"
            App.busy = false
            App.debug_reenable
          end
        end
        GuiTabHelpers.save_plugins_settings(e_plugins_dir, e_build, e_product, e_install_ids, combo_arch, combo_products, chk_dry)
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
          log.append("ERROR: Plugins dir is required for Update selected plugins.\n")
          status_label.text = "Error: missing plugins dir"
          next
        end
        ids = [] of String
        if table = App.installed_table
          table.selection do |sel|
            sel.rows.each do |row|
              plugin = App.installed_plugins_arr[row]?
              ids << plugin.id if plugin
            end
          end
        end
        if ids.empty?
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

    plugins_tab
  end
end
