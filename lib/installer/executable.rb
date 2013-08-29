require 'installer/helpers'
require 'installer/exceptions'

module Installer
  class Executable
    include Installer::Helpers

    attr_reader :command

    def initialize workflow_id, exec_string
      #Test to make sure the executable is present and runnable
      exec_file = which(exec_string.split(' ')[0])
      if exec_file.nil?
        raise Installer::WorkflowExecutableException, "Executable '#{exec_string}' for workflow '#{workflow_id}' could not be found or is not executable."
      end
      @command = exec_string
    end

    def run
      IO.popen(command).each do |line|
        p line.chomp
      end
    end

    private
    # SOURCE for #which:
    # http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each { |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable? exe
        }
      end
      return nil
    end

  end
end
