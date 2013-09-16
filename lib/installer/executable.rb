require 'installer/helpers'
require 'installer/exceptions'

module Installer
  class Executable
    include Installer::Helpers

    attr_reader :command, :status

    def initialize workflow, exec_string
      @workflow = workflow
      @status = nil
      #Test to make sure the executable is present and runnable
      expanded_exec = expand_path(exec_string)
      exec_file = which(expanded_exec.split(' ')[0])
      if exec_file.nil?
        raise Installer::WorkflowExecutableException, "Executable command '#{exec_string}' for workflow '#{workflow.id}' could not be found or is not executable."
      end
      @command = expanded_exec
    end

    def run workflow_cfg
      system expand_workflow_variables(workflow_cfg)
      @status = $?.exitstatus
    end

    private
    def workflow
      @workflow
    end

    def expand_path exec_string
      #TODO: add URL handling
      expand_map =
      { '<wokflow_id>' => workflow.id,
        '<gem_root_dir>' => gem_root_dir,
        '<workflow_path>' => workflow.path,
      }
      work_string = exec_string.dup
      expand_map.each_pair do |k,v|
        work_string.sub!(/#{k}/, v)
      end
      work_string
    end

    def expand_workflow_variables workflow_cfg
      work_string = command.dup
      workflow_cfg.each_pair do |k,v|
        qtag = "<q\:#{k}>"
        work_string.sub!(/#{qtag}/, v)
      end
      work_string
    end

    # Original source for #which:
    # http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
    def which(cmd)
      # First, a basic test to handle absolute paths to scripts
      if File.exists?(cmd) and File.executable?(cmd)
        return cmd
      end

      # Now the full smarts
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
