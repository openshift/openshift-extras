require 'fileutils'
require 'installer/deployment'
require 'installer/helpers'
require 'installer/subscription'
require 'yaml'

module Installer
  class Config
    include Installer::Helpers

    attr_reader :default_dir, :default_file, :file_template
    attr_accessor :file_path

    def initialize config_file_path=nil
      @default_dir = ENV['HOME'] + '/.openshift'
      @default_file = '/oo-install-cfg.yml'
      @file_template = gem_root_dir + "/config/oo-install-cfg.yml#{ get_context == :ose ? '.ose' : '' }.example"
      if config_file_path.nil?
        @file_path = default_dir + default_file
      else
        @file_path = config_file_path
      end
      if not file_check(@file_path)
        install_default(config_file_path)
        @new_config = true
      end
    end

    def settings
      @settings ||= YAML.load_file(self.file_path)
    end

    def is_valid?
      unless settings
        puts "Could not parse settings from #{self.file_path}."
        return false
      end
      unless installer_version_gte?(settings['Version'])
        puts "Config file is for a newer version of oo-installer."
        return false
      end
      true
    end

    def new_config?
      @new_config ||= false
    end

    def save_to_disk!
      File.open(file_path, 'w') do |file|
        file.write settings.to_yaml
      end
    end

    def get_deployment
      Installer::Deployment.new(self, (settings.has_key?('Deployment') ? settings['Deployment'] : {}))
    end

    def get_subscription
      Installer::Subscription.new(self, (settings.has_key?('Subscription') ? settings['Subscription'] : {}))
    end

    def set_deployment deployment
      settings['Deployment'] = deployment.to_hash
    end

    def set_subscription subscription
      settings['Subscription'] = subscription.to_hash
    end

    def get_workflow_cfg id
      (settings.has_key?('Workflows') and settings['Workflows'].has_key?(id)) ? settings['Workflows'][id] : {}
    end

    def set_workflow_cfg id, workflow_cfg
      if not settings.has_key?('Workflows')
        settings['Workflows'] = {}
      end
      settings['Workflows'][id] = workflow_cfg
    end

    private
    def install_default(provided_path)
      if provided_path.nil? and not Dir.entries(ENV['HOME']).include?('.openshift')
        Dir.mkdir(default_dir)
      end
      FileUtils.cp file_template, file_path
    end
  end
end

