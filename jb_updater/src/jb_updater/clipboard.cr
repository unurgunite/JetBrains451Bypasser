module JBUpdater
  # Minimal cross-platform clipboard helper used by the GUI.
  #
  # Delegates to the platform clipboard program:
  # - **macOS**: `pbcopy`
  # - **Linux**: `wl-copy`, then `xclip`, then `xsel`
  # - **Windows**: `clip`
  #
  # Returns `false` when no suitable clipboard program is available.
  module Clipboard
    extend self

    # Copies `text` to the system clipboard.
    #
    # @param text [String] Text to copy
    # @return [Bool] `true` when copied successfully
    def copy(text : String) : Bool
      {% if flag?(:darwin) %}
        run_copy("pbcopy", text)
      {% elsif flag?(:win32) %}
        run_copy("clip", text)
      {% else %}
        copy_linux(text)
      {% end %}
    end

    private def copy_linux(text : String) : Bool
      ["wl-copy", "xclip", "xsel"].each do |tool|
        return true if run_copy(tool, text)
      end
      false
    end

    private def run_copy(tool : String, text : String) : Bool
      command = tool
      args = [] of String
      if tool == "xclip"
        args = ["-selection", "clipboard"]
      elsif tool == "xsel"
        args = ["--clipboard", "--input"]
      end
      Process.run(command, args: args, input: IO::Memory.new(text),
        output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue
      false
    end
  end
end
