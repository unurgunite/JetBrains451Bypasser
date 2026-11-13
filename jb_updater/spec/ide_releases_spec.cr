require "./spec_helper"
include JBUpdater

describe IDEReleases do
  describe "#extract_releases_arr" do
    it "returns the exact-code array when present" do
      data = JSON.parse(%({"RM":[{"version":"2026.2.1"}]}))
      if arr = IDEReleases.extract_releases_arr(data, "RM")
        arr.size.should eq 1
      else
        fail "expected releases array"
      end
    end

    it "falls back to the variant key when the exact code is absent" do
      # JetBrains returns "IIU" for code "IU" — the code key must not win.
      data = JSON.parse(%({"IIU":[{"version":"2026.2.1"},{"version":"2026.2"}]}))
      if arr = IDEReleases.extract_releases_arr(data, "IU")
        arr.size.should eq 2
      else
        fail "expected releases array"
      end
    end

    it "returns nil when the response has no array values" do
      data = JSON.parse(%({"error":"boom"}))
      IDEReleases.extract_releases_arr(data, "RM").should be_nil
    end

    it "returns nil for an empty response object" do
      data = JSON.parse(%({}))
      IDEReleases.extract_releases_arr(data, "RM").should be_nil
    end
  end

  describe IDERelease do
    it "defaults checksum_link and size to nil" do
      rel = IDERelease.new(
        version: "2026.2.3",
        channel: "release",
        date: "2026-09-18",
        link: URI.parse("https://download-cdn.jetbrains.com/ruby/RM.dmg")
      )
      rel.checksum_link.should be_nil
      rel.size.should be_nil
    end

    it "stores checksum link and size" do
      rel = IDERelease.new(
        version: "2026.2.3",
        channel: "release",
        date: "2026-09-18",
        link: URI.parse("https://download-cdn.jetbrains.com/ruby/RM.dmg"),
        checksum_link: URI.parse("https://download-cdn.jetbrains.com/ruby/RM.dmg.sha256"),
        size: 1015459827_i64
      )
      rel.checksum_link.try(&.to_s).should eq "https://download-cdn.jetbrains.com/ruby/RM.dmg.sha256"
      rel.size.should eq 1015459827_i64
    end
  end
end
