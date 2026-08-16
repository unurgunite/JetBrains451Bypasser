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
end
