require "./spec_helper"
include JBUpdater

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
      app_path = "/Applications/RubyMine.app"
      # We only test that it tries to read; if the app doesn't exist, falls through
      result = DetectProducts.build_code("RubyMine", "RM", app_path)
      # On this machine it should exist and return something like RM-261.25134.97
      result.should match(/\ARM-\d+/)
    end
  end

  describe ".read_build_from_app" do
    it "reads from product-info.json for a real app" do
      result = DetectProducts.read_build_from_app("/Applications/RubyMine.app", "RM")
      result.should_not be_nil
      result.should match(/\ARM-/)
    end

    it "returns nil for non-existent path" do
      result = DetectProducts.read_build_from_app("/Applications/NonExistentIDE.app", "XX")
      result.should be_nil
    end
  end

  describe ".app_metadata_path" do
    it "constructs the correct macOS path for product-info.json" do
      path = DetectProducts.app_metadata_path("/Applications/RubyMine.app", "product-info.json")
      path.should eq "/Applications/RubyMine.app/Contents/Resources/product-info.json"
    end
  end

  describe ".all" do
    it "returns an array of DetectedProduct" do
      products = DetectProducts.all
      products.should be_a(Array(DetectedProduct))
    end

    it "contains RubyMine, WebStorm, and CLion on this machine" do
      products = DetectProducts.all
      names = products.map(&.name)
      names.any? { |n| n =~ /RubyMine|Rubymine/i }.should be_true
      names.any? { |n| n =~ /WebStorm|Webstorm/i }.should be_true
      names.any? { |n| n =~ /CLion|Clion/i }.should be_true
    end

    it "has non-empty code and build for each product" do
      products = DetectProducts.all
      products.each do |p|
        p.code.should_not be_empty
        p.build.should_not be_empty
        p.build.should match(/\A[A-Z]+-\d/)
      end
    end
  end
end
