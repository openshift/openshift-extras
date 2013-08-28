require 'pathname'
require 'yaml'

module Installer
  module Helpers
    def self.file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end
    def self.gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
    end
    def self.worflow_ids
      @workflow_ids ||= YAML.load_stream(open(gem_root_dir + '/conf/workflows.yml')).map{ |workflow| workflow['ID'] }
    end
  end
end

