require "./detect_products"

module JBUpdater
  module GUI
    module Actions
      # -- Resolve build code from IDE/Plugins tab fields or auto-detect --
      def self.resolve_build(
        ide_product_text : String?,
        build_text : String?,
        detected : Array(DetectedProduct)
      ) : String
        code = ide_product_text
        return code if code && !code.empty?
        code = build_text
        return code if code && !code.empty?
        if d = detected.first?
          return d.build
        end
        "IC-252"
      end

      # -- Thread-safe install queue (xml_id, plugins_dir, build) --
      @@queue = Array(Tuple(String, String, String)).new
      @@queue_mutex = Mutex.new
      @@processing = false
      @@total = 0

      def self.enqueue(xml_id : String, plugins_dir : String, build : String)
        @@queue_mutex.synchronize { @@queue << {xml_id, plugins_dir, build} }
      end

      def self.dequeue : Tuple(String, String, String)?
        @@queue_mutex.synchronize { @@queue.shift? }
      end

      def self.queue_size : Int32
        @@queue_mutex.synchronize { @@queue.size }
      end

      def self.processing? : Bool
        @@queue_mutex.synchronize { @@processing }
      end

      def self.processing=(v : Bool)
        @@queue_mutex.synchronize { @@processing = v }
      end

      def self.total : Int32
        @@queue_mutex.synchronize { @@total }
      end

      def self.total=(n : Int32)
        @@queue_mutex.synchronize { @@total = n }
      end

      def self.reset_queue
        @@queue_mutex.synchronize {
          @@queue.clear
          @@total = 0
          @@processing = false
        }
      end
    end
  end
end
