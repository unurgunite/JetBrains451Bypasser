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

    # Prints a red fatal error with an optional hint, then exits(1).
    #
    # Unlike an unhandled exception, this never dumps a backtrace —
    # the user gets the cause and what to do next.
    #
    # @param msg [String] Error message
    # @param hint [String?] Follow-up suggestion
    def fatal(msg : String, hint : String? = nil) : NoReturn
      fail(msg)
      if hint
        STDERR.puts "  → #{hint}"
        emit("  → #{hint}")
      end
      exit 1
    end

    # Converts a low-level exception into a human-readable message.
    #
    # @param ex [Exception] The error to explain
    # @return [Tuple(String, String?)] Message and optional hint
    def explain(ex : Exception) : Tuple(String, String?)
      case ex
      when Socket::ConnectError, Socket::Error, IO::TimeoutError
        {"Network error: #{ex.message}", "Check your connection or proxy. JBUpdater respects HTTP(S)_PROXY env vars."}
      when OpenSSL::SSL::Error
        {"TLS error: #{ex.message}", "The mirror may be blocked — try --ide-downloads-host or --downloads-host."}
      when File::NotFoundError
        {"File not found: #{ex.message}", nil}
      when File::AccessDeniedError
        {"Permission denied: #{ex.message}", "Re-run with sufficient rights or pick another directory."}
      else
        explain_runtime(ex)
      end
    end

    # Explains RuntimeError/Exception messages from HTTP and CLI layers.
    private def explain_runtime(ex : Exception) : Tuple(String, String?)
      msg = ex.message || ex.class.to_s
      if msg.starts_with?("HTTP 451")
        {msg, "Blocked (HTTP 451) — the CDN mirror should bypass this; retry or report the URL."}
      elsif msg.starts_with?("HTTP 429")
        {msg, "Rate limited — wait a minute and retry."}
      elsif msg.starts_with?("HTTP 5")
        {msg, "Server error — retry; downloads resume automatically."}
      elsif msg.includes?("Could not detect") || msg.includes?("Missing --")
        {msg, "Pass the missing option explicitly (see --help)."}
      elsif ex.is_a?(RuntimeError) || ex.is_a?(Exception)
        {msg, "Re-run with the same args; report with the failing command."}
      else
        {"#{ex.class}: #{msg}", "Re-run with the same args; report with the failing command."}
      end
    end
  end
end
