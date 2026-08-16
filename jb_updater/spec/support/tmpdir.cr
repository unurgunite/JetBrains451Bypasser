require "file_utils"

def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "jb_updater_test_#{Process.pid}_#{Random.rand(10000)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end
