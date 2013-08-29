require 'installer/helpers'
require 'versionomy'
require 'yaml'

module Installer
  class Config
    include Installer::Helpers

    attr_reader :default_dir, :default_file, :file_template
    attr_accessor :file_path, :workflow

    def initialize file_path=nil, workflow=nil
      @default_dir = ENV['HOME'] + '/.openshift'
      @default_file = '/oo-install-cfg.yml'
      @file_template = gem_root_dir + '/conf/oo-install-cfg.yml.example'
      if file_path.nil?
        self.file_path = default_dir + default_file
        unless file_check(self.file_path)
          install_default
        end
      else
        self.file_path = init_file_path
      end
      self.workflow = workflow
    end

    def settings
      @settings ||= YAML.load_file(self.file_path)
    end

    def is_valid?
      unless settings
        puts "Could not parse settings from #{self.file_path}."
        return false
      end
      unless Versionomy.parse(settings['Version']) <= Versionomy.parse(Installer::VERSION)
        puts "Config file is for a newer version of oo-installer."
        return false
      end
      true
    end

    private
    def install_default
      unless Dir.exists?(default_dir)
        Dir.mkdir(default_dir)
      end
      FileUtils.cp(file_template, self.file_path)
    end
  end
end

