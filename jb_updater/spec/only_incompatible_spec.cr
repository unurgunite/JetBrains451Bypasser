require "./spec_helper"

include JBUpdater

# Builds a fake plugins dir with one compatible and one incompatible plugin.
def build_mixed_plugins_dir(root : String) : String
  plugins = File.join(root, "plugins")
  compat = File.join(plugins, "compat.plugin")
  incompat = File.join(plugins, "old.plugin")
  FileUtils.mkdir_p(File.join(compat, "META-INF"))
  FileUtils.mkdir_p(File.join(incompat, "META-INF"))
  File.write(File.join(compat, "META-INF", "plugin.xml"),
    %(<idea-plugin><id>compat.plugin</id><version>1.0</version><idea-version since-build="241" until-build="253.*"/></idea-plugin>))
  File.write(File.join(incompat, "META-INF", "plugin.xml"),
    %(<idea-plugin><id>old.plugin</id><version>1.0</version><idea-version since-build="221" until-build="231.*"/></idea-plugin>))
  plugins
end

# Verifies --only-incompatible filtering via dry-run output capture.
describe "only-incompatible filter" do
  it "updates only incompatible plugins when the flag is set" do
    with_tmpdir do |dir|
      plugins_dir = build_mixed_plugins_dir(dir)
      opts = Options.new
      opts.plugins_dir = plugins_dir
      opts.build = "RM-252"
      opts.only_incompatible = true
      opts.dry_run = true
      updater = Updater.new(opts)

      lines = [] of String
      JBUpdater::Log.listener = ->(msg : String) { lines << msg; nil }
      begin
        updater.run(:update)
      ensure
        JBUpdater::Log.listener = nil
      end
      text = lines.join("\n")
      text.should contain "old.plugin"
      text.should_not contain "compat.plugin"
    end
  end

  it "updates all plugins without the flag" do
    with_tmpdir do |dir|
      plugins_dir = build_mixed_plugins_dir(dir)
      opts = Options.new
      opts.plugins_dir = plugins_dir
      opts.build = "RM-252"
      opts.dry_run = true
      updater = Updater.new(opts)

      lines = [] of String
      JBUpdater::Log.listener = ->(msg : String) { lines << msg; nil }
      begin
        updater.run(:update)
      ensure
        JBUpdater::Log.listener = nil
      end
      text = lines.join("\n")
      text.should contain "old.plugin"
      text.should contain "compat.plugin"
    end
  end
end
