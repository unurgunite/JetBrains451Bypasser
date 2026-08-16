require "process"

status = Process.run("cc", [
  "-c", "src/gui/layout_helper.m",
  "-o", "/tmp/jb_layout.o",
  "-fobjc-arc",
])
exit(status.exit_code? || 1)
