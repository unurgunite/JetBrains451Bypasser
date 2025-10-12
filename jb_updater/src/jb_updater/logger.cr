require "colorize"

module JBUpdater
  module Log
    extend self

    def header(line : String)
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts line.colorize(:cyan)
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    end

    def info(msg : String)
      puts "• #{msg}"
    end

    def success(msg : String)
      puts "✔ #{msg}".colorize(:green)
    end

    def warn(msg : String)
      STDERR.puts "⚠ #{msg}".colorize(:yellow)
    end

    def fail(msg : String)
      STDERR.puts "✖ #{msg}".colorize(:red)
    end
  end
end
