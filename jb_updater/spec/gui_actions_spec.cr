require "./spec_helper"
include JBUpdater

module JBUpdater
  module GUI
    describe Actions do
      describe ".resolve_build" do
        it "returns ide_product_text when present" do
          detected = [DetectedProduct.new("Test", "TT", "TT-999", nil, nil, nil)]
          Actions.resolve_build("RM-252", "", detected).should eq "RM-252"
        end

        it "returns ide_product_text over build_text" do
          detected = [DetectedProduct.new("Test", "TT", "TT-999", nil, nil, nil)]
          Actions.resolve_build("RM-252", "WS-242", detected).should eq "RM-252"
        end

        it "falls back to build_text when ide_product_text is nil" do
          detected = [DetectedProduct.new("Test", "TT", "TT-999", nil, nil, nil)]
          Actions.resolve_build(nil, "WS-242", detected).should eq "WS-242"
        end

        it "falls back to build_text when ide_product_text is empty" do
          detected = [DetectedProduct.new("Test", "TT", "TT-999", nil, nil, nil)]
          Actions.resolve_build("", "WS-242", detected).should eq "WS-242"
        end

        it "falls back to first detected product" do
          detected = [
            DetectedProduct.new("WebStorm", "WS", "WS-242", nil, nil, nil),
            DetectedProduct.new("RubyMine", "RM", "RM-252", nil, nil, nil),
          ]
          Actions.resolve_build(nil, nil, detected).should eq "WS-242"
        end

        it "returns IC-252 when all inputs are empty" do
          Actions.resolve_build(nil, nil, [] of DetectedProduct).should eq "IC-252"
        end

        it "returns IC-252 when ide text and build text are empty and no detected" do
          Actions.resolve_build("", "", [] of DetectedProduct).should eq "IC-252"
        end
      end

      describe "install queue" do
        before_each do
          Actions.reset_queue
        end

        describe ".enqueue / .dequeue" do
          it "enqueues and dequeues items in FIFO order" do
            Actions.enqueue("plugin.a", "/dir", "IC-252")
            Actions.enqueue("plugin.b", "/dir", "RM-252")

            Actions.dequeue.should eq({"plugin.a", "/dir", "IC-252"})
            Actions.dequeue.should eq({"plugin.b", "/dir", "RM-252"})
          end

          it "returns nil when queue is empty" do
            Actions.dequeue.should be_nil
          end
        end

        describe ".queue_size" do
          it "returns 0 for empty queue" do
            Actions.queue_size.should eq 0
          end

          it "returns the number of items in the queue" do
            Actions.enqueue("a", "/d", "b")
            Actions.enqueue("c", "/d", "d")
            Actions.queue_size.should eq 2
          end
        end

        describe ".processing?" do
          it "returns false initially" do
            Actions.processing?.should be_false
          end

          it "returns true after setting" do
            Actions.processing = true
            Actions.processing?.should be_true
          end
        end

        describe ".total / .total=" do
          it "returns 0 initially" do
            Actions.total.should eq 0
          end

          it "stores the total count" do
            Actions.total = 5
            Actions.total.should eq 5
          end
        end

        describe ".reset_queue" do
          it "clears the queue and resets state" do
            Actions.enqueue("p", "/d", "b")
            Actions.processing = true
            Actions.total = 3
            Actions.reset_queue

            Actions.queue_size.should eq 0
            Actions.processing?.should be_false
            Actions.total.should eq 0
          end
        end
      end
    end
  end
end
