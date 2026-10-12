# IDE tab: release listing, download, and upgrade.
module IdeTab
  # Builds the tab content and wires all handlers.
  #
  # @param ctx [GuiCtx] Shared widgets and state
  # @return [UIng::Box] Tab root
  def self.build(ctx : GuiCtx) : UIng::Box
    log = ctx.log
    status_label = ctx.status_label
    e_ide_product = ctx.e_ide_product
    e_ide_path = ctx.e_ide_path
    chk_brew = ctx.chk_brew

    ide_tab = UIng::Box.new(:vertical)
    ide_tab.padded = true

    ide_group = UIng::Group.new("IDE Configuration", margined: true)
    ide_form = UIng::Form.new
    ide_form.padded = true

    ide_form.append("IDE code or name", e_ide_product, false)
    ide_form.append("IDE Path", e_ide_path, true)
    ide_group.child = ide_form
    ide_tab.append(ide_group, false)

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
          CliRunner.new_run_header("List IDE releases", ["--list-ide-releases", "--product", product])

          App.busy = true
          Thread.new do
            releases = JBUpdater::IDEReleases.fetch(
              code,
              channel: "release",
              arch: CliRunner::ARCH,
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

          GuiTabHelpers.save_ide_settings(e_ide_product, e_ide_path, chk_brew)
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

        CliRunner.new_run_header("Download #{rel.version}", [rel.link.to_s])

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

        CliRunner.new_run_header("Upgrade IDE", args)
        CliRunner.run(args)
        GuiTabHelpers.save_ide_settings(e_ide_product, e_ide_path, chk_brew)
      end
    end

    ide_tab
  end
end
