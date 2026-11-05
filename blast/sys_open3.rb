# Replace SequenceServer's fork+exec helper with Open3 (spawn-based).
#
# Running the amd64 SequenceServer image under QEMU on arm64 hosts (for
# example Docker Desktop on Apple Silicon) can deadlock when Ruby forks a
# multi-threaded process. Open3.capture3 uses spawn instead, which works
# under QEMU. This file is only mounted by compose.local.yml; production
# x86_64 deployments use SequenceServer's stock implementation.
require 'open3'
require 'fileutils'

module SequenceServer
  class << self
    def sys(command, options = {})
      env = {}
      env['PATH'] = options[:path] if options[:path]

      spawn_opts = {}
      spawn_opts[:chdir] = options[:dir] if options[:dir] && Dir.exist?(options[:dir])

      stdout, stderr, status = Open3.capture3(env, command, **spawn_opts)

      %i[stdout stderr].each do |channel|
        filename = options[channel]
        next unless filename

        dir = File.dirname(filename)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        File.write(filename, channel == :stdout ? stdout : stderr)
      end

      return [stdout, stderr] if status.success?

      raise CommandFailed.new(status.exitstatus, stdout: stdout, stderr: stderr)
    end
  end
end
