require "./spec_helper"
include JBUpdater

# Creates a temporary fixture directory with product-info.json at the right path
# for the current platform. Returns {app_path, cleanup_proc}.
private def with_product_info_fixture(build_number : String)
  tmpdir = Dir.tempdir
  subdir = File.join(tmpdir, "jb_spec_#{Process.pid}_#{Random.rand(10000)}")
  Dir.mkdir(subdir)

  app_path = nil
  info_json_path = nil

  if {{ flag?(:darwin) }}
    resources = File.join(subdir, "Contents", "Resources")
    Dir.mkdir_p(resources)
    info_json_path = File.join(resources, "product-info.json")
    app_path = subdir
  else
    ide_dir = File.join(subdir, "ide")
    Dir.mkdir(ide_dir)
    info_json_path = File.join(subdir, "product-info.json")
    app_path = ide_dir
  end

  File.write(info_json_path.not_nil!, %({"buildNumber": "#{build_number}"}))
  {app_path.not_nil!, ->{ FileUtils.rm_rf(subdir) }}
end

describe DetectProducts do
  describe ".infer_code" do
    it "maps RubyMine to RM" do
      DetectProducts.infer_code("RubyMine2025.2").should eq "RM"
    end

    it "maps WebStorm to WS" do
      DetectProducts.infer_code("WebStorm2025.1").should eq "WS"
    end

    it "maps PyCharm to PY" do
      DetectProducts.infer_code("PyCharm2024.3").should eq "PY"
    end

    it "maps CLion to CL" do
      DetectProducts.infer_code("CLion2025.1").should eq "CL"
    end

    it "maps GoLand to GO" do
      DetectProducts.infer_code("GoLand2025.2").should eq "GO"
    end

    it "maps IntelliJ to IU" do
      DetectProducts.infer_code("IntelliJ IDEA 2025.2").should eq "IU"
    end

    it "maps PhpStorm to PS" do
      DetectProducts.infer_code("PhpStorm2025.1").should eq "PS"
    end

    it "maps Rider to RD" do
      DetectProducts.infer_code("Rider2025.1").should eq "RD"
    end

    it "returns first 2 uppercase chars for unknown names" do
      DetectProducts.infer_code("MyCustomIDE").should eq "MY"
    end

    it "strips version number before lookup" do
      DetectProducts.infer_code("RubyMine2025.2.1").should eq "RM"
    end

    it "strips trailing words for IntelliJ IDEA" do
      DetectProducts.infer_code("IntelliJ IDEA 2025.2 Ultimate").should eq "IU"
    end
  end

  describe ".build_code" do
    it "constructs RM-252 from RubyMine2025.2" do
      DetectProducts.build_code("RubyMine2025.2", "RM").should eq "RM-252"
    end

    it "constructs WS-251 from WebStorm2025.1" do
      DetectProducts.build_code("WebStorm2025.1", "WS").should eq "WS-251"
    end

    it "constructs CL-251 from CLion2025.1" do
      DetectProducts.build_code("CLion2025.1", "CL").should eq "CL-251"
    end

    it "constructs IU-252 from IntelliJ IDEA 2025.2" do
      DetectProducts.build_code("IntelliJ IDEA 2025.2", "IU").should eq "IU-252"
    end

    it "handles single-digit year" do
      DetectProducts.build_code("RubyMine2024.3", "RM").should eq "RM-243"
    end

    it "returns code-version when name has no version and no ide_path" do
      DetectProducts.build_code("Foo", "FO").should eq "FO-"
    end

    it "reads from app bundle when no version in name" do
      app_path, cleanup = with_product_info_fixture("261.99999.999")
      begin
        result = DetectProducts.build_code("RubyMine", "RM", app_path)
        result.should eq "RM-261.99999.999"
      ensure
        cleanup.call
      end
    end
  end

  describe ".read_build_from_app" do
    it "reads from product-info.json using a temp fixture" do
      app_path, cleanup = with_product_info_fixture("261.12345.67")
      begin
        result = DetectProducts.read_build_from_app(app_path, "RM")
        result.should eq "RM-261.12345.67"
      ensure
        cleanup.call
      end
    end

    it "returns nil for non-existent path" do
      DetectProducts.read_build_from_app("/tmp/__nonexistent_ide_app__", "XX").should be_nil
    end
  end

  describe ".app_metadata_path" do
    it "constructs the correct platform-specific path for product-info.json" do
      path = DetectProducts.app_metadata_path("/Applications/RubyMine.app", "product-info.json")
      {% if flag?(:darwin) %}
        path.should eq "/Applications/RubyMine.app/Contents/Resources/product-info.json"
      {% else %}
        path.should eq "/Applications/product-info.json"
      {% end %}
    end
  end

  describe ".all" do
    it "returns an array of DetectedProduct" do
      products = DetectProducts.all
      products.should be_a(Array(DetectedProduct))
    end

    it "has non-empty code and build for each product when any found" do
      products = DetectProducts.all
      products.each do |p|
        p.code.should_not be_empty
        p.build.should_not be_empty
        p.build.should match(/\A[A-Z]+-\d/)
      end
    end

    it "sorts detected products alphabetically by name" do
      products = DetectProducts.all
      # If we have at least 2 products, verify ordering
      next if products.size < 2
      names = products.map(&.name.downcase)
      names.should eq names.sort
    end
  end
end
