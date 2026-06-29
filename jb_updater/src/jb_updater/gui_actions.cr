require "./detect_products"

module JBUpdater
  module GUI
    # GUI-specific action helpers extracted from `main_gui.cr`.
    #
    # Provides the build resolution chain and a thread-safe install queue
    # used by the Browse tab's sequential plugin installer.
    module Actions
      # Resolves the IDE build string from user input or auto-detection.
      #
      # Priority:
      # 1. `ide_product_text` (IDE tab's "IDE code or name" field)
      # 2. `build_text` (Plugins tab's "Build" field)
      # 3. First detected product's build from {DetectProducts.all}
      # 4. Fallback `"IC-252"`
      #
      # @param ide_product_text [String?] Value from the IDE code/name field
      # @param build_text [String?] Value from the build field
      # @param detected [Array(DetectedProduct)] Auto-detected products
      # @return [String] Resolved build string
      def self.resolve_build(
        ide_product_text : String?,
        build_text : String?,
        detected : Array(DetectedProduct),
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

      @@queue = Array(Tuple(String, String, String)).new
      @@queue_mutex = Mutex.new
      @@processing = false
      @@total = 0

      # Adds a plugin installation task to the queue.
      #
      # @param xml_id [String] Plugin XML identifier
      # @param plugins_dir [String] Target plugins directory
      # @param build [String] IDE build string
      def self.enqueue(xml_id : String, plugins_dir : String, build : String)
        @@queue_mutex.synchronize { @@queue << {xml_id, plugins_dir, build} }
      end

      # Removes and returns the next item from the queue.
      #
      # @return [Tuple(String, String, String)?] Next task or nil
      def self.dequeue : Tuple(String, String, String)?
        @@queue_mutex.synchronize { @@queue.shift? }
      end

      # Returns the current number of queued tasks.
      #
      # @return [Int32]
      def self.queue_size : Int32
        @@queue_mutex.synchronize { @@queue.size }
      end

      # Whether the queue processor is currently running.
      #
      # @return [Bool]
      def self.processing? : Bool
        @@queue_mutex.synchronize { @@processing }
      end

      # @param v [Bool] New processing state
      def self.processing=(v : Bool)
        @@queue_mutex.synchronize { @@processing = v }
      end

      # Returns the total number of tasks enqueued during the current batch.
      #
      # @return [Int32]
      def self.total : Int32
        @@queue_mutex.synchronize { @@total }
      end

      # @param n [Int32] New total
      def self.total=(n : Int32)
        @@queue_mutex.synchronize { @@total = n }
      end

      # Clears the queue and resets counters.
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
