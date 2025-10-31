require "./spec_helper"
include JBUpdater

describe Utils do
  describe ".safe" do
    it "replaces forbidden characters with underscores" do
      Utils.safe("a/b:c*?.zip").should eq "a_b_c__.zip"
    end
  end

  describe ".parse_build_string" do
    it "parses numeric build" do
      Utils.parse_build_string("2024.1.2").should eq [2024.0, 1.0, 2.0]
    end

    it "accepts wildcards" do
      Utils.parse_build_string("2024.1.*").should eq [2024.0, 1.0, Float64::INFINITY]
    end
  end

  describe ".build_in_range?" do
    it "returns true when build is between since/until" do
      Utils.build_in_range?("2024.1.2", "2024.0.0", "2024.2.0").should be_true
    end

    it "returns false when build is below since" do
      Utils.build_in_range?("2023.1.0", "2024.0.0", "2024.3.0").should be_false
    end
  end
end
