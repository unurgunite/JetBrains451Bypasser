# Browse tab: marketplace search, plugin table, install actions.
module BrowseTab
  # Builds the tab content and wires all handlers.
  #
  # @param ctx [GuiCtx] Shared widgets and state
  # @return [NamedTuple(box: UIng::Box, content: UIng::Box, detail_box: UIng::Box)]
  def self.build(ctx : GuiCtx)
    log = ctx.log
    e_plugins_dir = ctx.e_plugins_dir
    e_ide_product = ctx.e_ide_product
    e_build = ctx.e_build

    browse_tab = UIng::Box.new(:vertical)
    browse_tab.padded = true

    browse_content = UIng::Box.new(:horizontal)
    browse_content.padded = true

    browse_left = UIng::Box.new(:vertical)
    browse_left.padded = true

    browse_header = UIng::Box.new(:horizontal)
    browse_header.padded = true

    search_entry = UIng::Entry.new
    search_entry.text = ""

    btn_top = UIng::Button.new("Top Downloaded")
    btn_newest = UIng::Button.new("Newest")
    btn_refresh = UIng::Button.new("Refresh")

    browse_header.append(search_entry, true)
    browse_header.append(btn_top, false)
    browse_header.append(btn_newest, false)
    browse_header.append(btn_refresh, false)
    browse_left.append(browse_header, false)

    browse_model_handler = UIng::Table::Model::Handler.new do
      num_columns { 4 }
      column_type { |_col| UIng::Table::Value::Type::String }
      num_rows { App.browse_plugins.size }
      cell_value do |row, col|
        if row < App.browse_plugins.size
          plugin = App.browse_plugins[row]
          case col
          when 0 then UIng::Table::Value.new(plugin.compat_note ? "⚠ #{plugin.name}" : plugin.name)
          when 1
            installed = App.installed_plugins
            value = installed ? (installed.has_key?(plugin.xml_id) ? "✓" : "") : "—"
            UIng::Table::Value.new(value)
          when 2 then UIng::Table::Value.new(plugin.formatted_downloads)
          else        UIng::Table::Value.new(plugin.star_rating)
          end
        else
          UIng::Table::Value.new("")
        end
      end
    end

    browse_model = UIng::Table::Model.new(browse_model_handler)
    browse_table = UIng::Table.new(browse_model)
    browse_table.header_visible = true
    browse_table.selection_mode = :one

    browse_table.append_text_column("Plugin", 0, -1)
    browse_table.append_text_column("Installed", 1, -1)
    browse_table.append_text_column("Downloads", 2, -1)
    browse_table.append_text_column("Rating", 3, -1)
    browse_table.column_set_width(0, 260)
    browse_table.column_set_width(1, 60)
    browse_table.column_set_width(2, 100)
    browse_table.column_set_width(3, 80)

    browse_table.on_header_clicked do |column|
      next unless {0, 2, 3}.includes?(column)

      (0...4).each do |col|
        browse_table.header_set_sort_indicator(col, :none) if col != column
      end

      current = browse_table.header_sort_indicator(column)
      ascending = current.none? || current.descending?

      plugins = App.browse_plugins
      case column
      when 0 then plugins.sort! { |x, y| ascending ? x.name <=> y.name : y.name <=> x.name }
      when 2 then plugins.sort! { |x, y| ascending ? x.downloads <=> y.downloads : y.downloads <=> x.downloads }
      when 3 then plugins.sort! { |x, y| ascending ? x.rating <=> y.rating : y.rating <=> x.rating }
      end

      new_indicator = ascending ? UIng::Table::SortIndicator::Ascending : UIng::Table::SortIndicator::Descending
      browse_table.header_set_sort_indicator(column, new_indicator)

      plugins.each_with_index { |_, i| browse_model.row_changed(i) }
    end

    browse_left.append(browse_table, true)

    App.browse_table_model = browse_model
    App.browse_handler = browse_model_handler

    browse_actions = UIng::Box.new(:horizontal)
    browse_actions.padded = true

    btn_install_browse = UIng::Button.new("Install Selected")
    btn_copy_id = UIng::Button.new("Copy XML ID")

    browse_actions.append(btn_install_browse, false)
    browse_actions.append(btn_copy_id, false)
    browse_left.append(browse_actions, false)

    browse_status = UIng::Label.new("Click search or a button to browse plugins")
    browse_status_box = UIng::Box.new(:horizontal)
    browse_status_box.padded = true
    browse_status_box.append(browse_status, true)
    browse_left.append(browse_status_box, false)

    # Diff-updates the browse table and status after a fetch completes.
    # Must run on the UI thread (called from UIng.queue_main).
    browse_update = ->(plugins : Array(JBUpdater::PluginInfo), status : String) {
      if model = App.browse_table_model
        old_count = App.browse_plugins.size
        App.browse_plugins = plugins
        if old_count == 0
          plugins.each_with_index { |_, i| model.row_inserted(i) }
        elsif plugins.size >= old_count
          (0...old_count).each { |i| model.row_changed(i) }
          (old_count...plugins.size).each { |i| model.row_inserted(i) }
        else
          (0...plugins.size).each { |i| model.row_changed(i) }
          (plugins.size...old_count).reverse_each { |i| model.row_deleted(i) }
        end
      end
      browse_status.text = status
      App.log.append("[Browse] #{status}\n")
    }

    browse_detail_box = UIng::Box.new(:vertical)
    browse_detail_box.padded = true
    detail_label = UIng::Label.new("Plugin Details")
    browse_detail = UIng::MultilineEntry.new(true, true)
    App.safe_set_text(browse_detail, "Select a plugin to view details")
    App.browse_detail = browse_detail

    browse_detail_box.append(detail_label, false)
    browse_detail_box.append(browse_detail, true)
    browse_content.append(browse_left, true)
    browse_content.append(browse_detail_box, false)
    browse_tab.append(browse_content, true)

    resolve_build = -> : String {
      products = App.detected_products || JBUpdater::DetectProducts.all
      result = JBUpdater::GUI::Actions.resolve_build(e_ide_product.text, e_build.text, products)
      if result != e_ide_product.text && result != e_build.text
        log.append("[Browse] Auto-detected build: #{result}\n")
      end
      result
    }

    search_entry.on_changed do |text|
      query = text || ""
      App.search_id += 1
      my_id = App.search_id

      if query.empty?
        if model = App.browse_table_model
          old_count = App.browse_plugins.size
          App.browse_plugins = [] of JBUpdater::PluginInfo
          (0...old_count).each { |_| model.row_deleted(0) }
        end
        App.selected_xml_id = nil
        browse_status.text = "Type to search plugins..."
      else
        build = resolve_build.call
        browse_status.text = "Searching..."
        # Filtering runs on a background thread and is debounced so rapid
        # keystrokes only trigger the final query (bug CB2).
        Thread.new do
          sleep 250.milliseconds
          if my_id == App.search_id
            begin
              plugins = JBUpdater::PluginMarketplace.search(query, build)
              UIng.queue_main do
                next if App.shutting_down?
                if my_id == App.search_id
                  browse_update.call(plugins, "Found #{plugins.size} results")
                end
              end
            rescue ex
              UIng.queue_main do
                next if App.shutting_down?
                if my_id == App.search_id
                  App.log.append("[Browse] Search error: #{ex.class}: #{ex.message}\n")
                  browse_status.text = "Search error: #{ex.message}"
                end
              end
            end
          end
        end
      end
    rescue ex
      App.log.append("[Browse] Search error: #{ex.class}: #{ex.message}\n")
      browse_status.text = "Search error: #{ex.message}"
    end

    btn_top.on_clicked do
      build = resolve_build.call
      App.search_id += 1
      browse_status.text = "Fetching top plugins..."
      log.append("[Browse] Fetching top downloaded for build #{build}...\n")
      Thread.new do
        plugins = JBUpdater::PluginMarketplace.top_downloaded(build, 100)
        UIng.queue_main do
          next if App.shutting_down?
          plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }
          browse_update.call(plugins, "Loaded #{plugins.size} plugins (top downloads)")
        end
      rescue ex
        UIng.queue_main do
          next if App.shutting_down?
          log.append("[Browse] Top downloads error: #{ex.class}: #{ex.message}\n")
          browse_status.text = "Error: #{ex.message}"
        end
      end
    end

    btn_newest.on_clicked do
      build = resolve_build.call
      App.search_id += 1
      browse_status.text = "Fetching latest plugins..."
      log.append("[Browse] Fetching newest for build #{build}...\n")
      Thread.new do
        plugins = JBUpdater::PluginMarketplace.newest(build, 100)
        UIng.queue_main do
          next if App.shutting_down?
          plugins.first(3).each { |plugin| log.append("  #{plugin.name} (#{plugin.downloads} dl)\n") }
          browse_update.call(plugins, "Loaded #{plugins.size} plugins (latest)")
        end
      rescue ex
        UIng.queue_main do
          next if App.shutting_down?
          log.append("[Browse] Newest error: #{ex.class}: #{ex.message}\n")
          browse_status.text = "Error: #{ex.message}"
        end
      end
    end

    btn_refresh.on_clicked do
      UIng.queue_main do
        App.search_id += 1
        App.installed_plugins = nil
        App.selected_xml_id = nil
        JBUpdater::PluginMarketplace.clear_cache
        if model = App.browse_table_model
          old_count = App.browse_plugins.size
          (0...old_count).each { |_| model.row_deleted(0) }
          App.browse_plugins = [] of JBUpdater::PluginInfo
        end
        browse_status.text = "Cache cleared. Click Top Downloaded or Newest to reload."
      rescue ex
        log.append("[Browse] Refresh error: #{ex.class}: #{ex.message}\n")
        browse_status.text = "Refresh error: #{ex.message}"
      end
    end

    browse_table.on_selection_changed do |selection|
      row = selection.num_rows > 0 ? selection.rows[0] : -1
      plugin = row >= 0 ? App.browse_plugins[row]? : nil
      if plugin
        App.selected_xml_id = plugin.xml_id
        if note = plugin.compat_note
          App.safe_set_text(browse_detail, "⚠ #{note}\n\n#{plugin.description}")
        else
          stripped = plugin.description[0, 500]
          preview = stripped[0, 500]
          App.log.append("[Browse] detail: #{preview.size}B #{preview.count('\n')} lines (#{preview.size - preview.count('\n')} non-newline)\n")
          App.safe_set_text(browse_detail, preview)
        end
      else
        App.safe_set_text(browse_detail, "Select a plugin to view details")
        App.selected_xml_id = nil
      end
    end

    btn_install_browse.on_clicked do
      xml_id = App.selected_xml_id
      if xml_id.nil? || xml_id.empty?
        browse_status.text = "Please select a plugin first"
        next
      end

      plugins_dir = e_plugins_dir.text
      if plugins_dir.nil? || plugins_dir.empty?
        browse_status.text = "Error: plugins dir not set. Switch to Main tab."
        next
      end

      build = resolve_build.call

      warn = App.browse_plugins.any? { |plugin| plugin.xml_id == xml_id && plugin.compat_note }
      log.append(warn ? "[Browse] ⚠ #{xml_id} may not be fully compatible with build #{build}; installing latest compatible version\n" : "[Browse] Installing plugin: #{xml_id} for build #{build}\n")
      browse_status.text = warn ? "Installing (compatibility warning)…" : "Installing…"

      GuiTabHelpers.queue_install(xml_id, plugins_dir, build)
    end

    btn_copy_id.on_clicked do
      xml_id = App.selected_xml_id
      if xml_id.nil? || xml_id.empty?
        browse_status.text = "Please select a plugin first"
      else
        copied = JBUpdater::Clipboard.copy(xml_id)
        log.append("[Browse] Copied XML ID: #{xml_id} (#{copied ? "ok" : "failed"})\n")
        browse_status.text = copied ? "Copied to clipboard: #{xml_id}" : "Copy to clipboard failed: #{xml_id}"
      end
    end

    {box: browse_tab, content: browse_content, detail_box: browse_detail_box}
  end
end
