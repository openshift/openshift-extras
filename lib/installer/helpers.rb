require 'pathname'

module Originator
  module Helpers
    def self.file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end
    def self.gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
    end
  end
end

