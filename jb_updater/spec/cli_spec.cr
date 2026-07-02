require "./spec_helper"
include JBUpdater

describe Options do
  describe "#initialize" do
    it "defaults all fields to nil/false/empty" do
      o = Options.new
      o.plugins_dir.should be_nil
      o.build.should be_nil
      o.only.should be_empty
      o.only_incompatible?.should be_false
      o.dry_run?.should be_false
      o.downloads_host.should eq "downloads.marketplace.jetbrains.com"
      o.pin_versions.should be_empty
      o.direct_urls.should be_empty
      o.list?.should be_false
      o.bin_path.should be_nil
      o.include_bundled?.should be_false
      o.install_ids.should be_empty
      o.product.should be_nil
      o.ide_path.should be_nil
      o.brew_patch.should be_false
      o.upgrade_ide?.should be_false
      o.ide_downloads_host.should eq "download-cdn.jetbrains.com"
      o.arch.should be_nil
      o.list_ide_releases?.should be_false
      o.no_tty_progress_bar?.should be_false
    end
  end
end

describe JBUpdater do
  describe ".parse_cli" do
    it "parses --help and sets list flag" do
      opts = JBUpdater.parse_cli(["-l"])
      opts.list?.should be_true
    end

    it "parses --build" do
      opts = JBUpdater.parse_cli(["-b", "RM-252"])
      opts.build.should eq "RM-252"
    end

    it "parses --dry-run" do
      opts = JBUpdater.parse_cli(["--dry-run"])
      opts.dry_run?.should be_true
    end

    it "parses --plugins-dir" do
      opts = JBUpdater.parse_cli(["--plugins-dir", "/custom/path"])
      opts.plugins_dir.should eq "/custom/path"
    end

    it "parses --install-plugin" do
      opts = JBUpdater.parse_cli(["-i", "com.example.plugin,org.test"])
      opts.install_ids.should eq ["com.example.plugin", "org.test"]
    end
  end
end
