require 'installer/helpers'

module Installer
  class District
    include Installer::Helpers

    attr_accessor :profile_name, :gear_size, :node_hosts

    def initialize district_config
      @profile_name = district_config['profile_name']
      @gear_size    = district_config['gear_size']
      @node_hosts   = district_config['node_hosts'].split(',').map{ |s| s.strip }
    end

    def add_node_host(host_instance)
      @node_hosts = node_hosts.concat([host_instance.host]).uniq
    end

    def remove_node_host(host_instance)
      @node_hosts.delete_if{ |h| h == host_instance.host }
    end

    def is_valid?(check=:basic,node_instances,broker_global)
      errors = []
      if not is_valid_string?(profile_name)
        return false if check == :basic
        errors << Installer::DistrictSettingsException.new("One of the districts has an invalid or unset profile name.")
      end
      node_hosts.each do |hostname|
        if node_instances.select{ |h| h.host == hostname }.length == 0
          return false if check == :basic
          errors << Installer::DistrictSettingsException.new("Node host '#{hostname}' from the '#{profile_name}' district can't be found in the deployment.")
        end
      end
      if not broker_global.valid_gear_sizes.include?(gear_size)
        return false if check == :basic
        errors << Installer::DistrictSettingsException.new("Gear size '#{gear_size}' for district '#{profile_name}' is not a valid gear size.")
      end
      errors
    end

    def to_hash
      {
        'profile_name' => profile_name,
        'gear_size'    => gear_size,
        'node_hosts'   => node_hosts.join(',')
      }
    end

  end
end
