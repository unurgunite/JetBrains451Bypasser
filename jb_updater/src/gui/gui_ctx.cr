# Shared widget context passed to GUI tab builders.
#
# All widgets are created once in `main_gui.cr`; tab modules receive
# this context to build their content and wire event handlers without
# relying on top-level locals.
class GuiCtx
  property log : UIng::MultilineEntry
  property status_label : UIng::Label
  property tabs : UIng::Tab
  property e_plugins_dir : UIng::Entry
  property e_build : UIng::Entry
  property e_product : UIng::Entry
  property e_install_ids : UIng::Entry
  property combo_arch : UIng::Combobox
  property combo_products : UIng::Combobox
  property chk_dry : UIng::Checkbox
  property e_ide_product : UIng::Entry
  property e_ide_path : UIng::Entry
  property chk_brew : UIng::Checkbox
  property detected : Array(JBUpdater::DetectedProduct)

  def initialize(
    @log, @status_label, @tabs,
    @e_plugins_dir, @e_build, @e_product, @e_install_ids,
    @combo_arch, @combo_products, @chk_dry,
    @e_ide_product, @e_ide_path, @chk_brew,
    @detected,
  )
  end
end
