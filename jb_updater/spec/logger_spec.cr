require "./spec_helper"

include JBUpdater

describe JBUpdater::Log do
  describe ".explain" do
    it "explains connection errors with a proxy hint" do
      msg, hint = JBUpdater::Log.explain(Socket::ConnectError.new("No route to host"))
      msg.should contain "Network error"
      (hint || "").should contain "PROXY"
    end

    it "explains HTTP 451 with a mirror hint" do
      msg, hint = JBUpdater::Log.explain(RuntimeError.new("HTTP 451 Unavailable For Legal Reasons"))
      msg.should contain "451"
      hint.should_not be_nil
    end

    it "explains HTTP 429 with a wait hint" do
      _, hint = JBUpdater::Log.explain(RuntimeError.new("HTTP 429 Too Many Requests"))
      (hint || "").should contain "wait"
    end

    it "explains missing options" do
      _, hint = JBUpdater::Log.explain(Exception.new("Could not detect IDE build; pass --build"))
      (hint || "").should contain "--help"
    end

    it "keeps plain messages without class prefix for generic errors" do
      msg, hint = JBUpdater::Log.explain(ArgumentError.new("bogus"))
      msg.should eq "bogus"
      hint.should_not be_nil
    end
  end
end
