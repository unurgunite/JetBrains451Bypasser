require "colorize"

module JBUpdater
  # Simple coloured logger used throughout the CLI and GUI.
  #
  # Output is written to stdout (or stderr for warnings and errors)
  # and forwarded to an optional callback so the GUI can display
  # log messages in its console widget.
  module Log
    extend self

    @@listener : Proc(String, Nil)? = nil

    # Registers a listener callback that receives every log line.
    #
    # Used by the GUI to forward log output to the on-screen console.
    #
    # @param cb [Proc(String, Nil)?] Callback or `nil` to unregister
    def listener=(cb : Proc(String, Nil)?)
      @@listener = cb
    end

    private def emit(msg : String)
      @@listener.try(&.call(msg))
    end

    # Prints a cyan section header framed by separator lines.
    #
    # @param line [String] Header text
    def header(line : String)
      sep = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts sep
      emit("── #{line} ──")
      puts line.colorize(:cyan)
      puts sep
    end

    # Prints a bullet-pointed info line.
    #
    # @param msg [String] Info message
    def info(msg : String)
      line = "• #{msg}"
      puts line
      emit(line)
    end

    # Prints a green checkmark success line.
    #
    # @param msg [String] Success message
    def success(msg : String)
      line = "✔ #{msg}"
      puts line.colorize(:green)
      emit(line)
    end

    # Prints a yellow warning to stderr.
    #
    # @param msg [String] Warning message
    def warn(msg : String)
      line = "⚠ #{msg}"
      STDERR.puts line.colorize(:yellow)
      emit(line)
    end

    # Prints a red error to stderr.
    #
    # @param msg [String] Error message
    def fail(msg : String)
      line = "✖ #{msg}"
      STDERR.puts line.colorize(:red)
      emit(line)
    end
  end
end
