require "./spec_helper"

describe JbUpdater do
  it "loads without crashing" do
    JbUpdater::VERSION.should match /^\d+\.\d+\.\d+$/
  end
end
