require "colorize"

module JBUpdater
  module Log
    extend self

    @@listener : Proc(String, Nil)? = nil

    def listener=(cb : Proc(String, Nil)?)
      @@listener = cb
    end

    private def emit(msg : String)
      @@listener.try(&.call(msg))
    end

    def header(line : String)
      sep = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts sep
      emit("── #{line} ──")
      puts line.colorize(:cyan)
      puts sep
    end

    def info(msg : String)
      line = "• #{msg}"
      puts line
      emit(line)
    end

    def success(msg : String)
      line = "✔ #{msg}"
      puts line.colorize(:green)
      emit(line)
    end

    def warn(msg : String)
      line = "⚠ #{msg}"
      STDERR.puts line.colorize(:yellow)
      emit(line)
    end

    def fail(msg : String)
      line = "✖ #{msg}"
      STDERR.puts line.colorize(:red)
      emit(line)
    end
  end
end
