require 'installer/helpers'
require 'installer/host_instance'
require 'installer/dns_config'
require 'set'

module Installer
  class Deployment
    include Installer::Helpers

    attr_reader :config
    attr_accessor :dns, :hosts

    class << self
      def role_map
        { :broker => 'Brokers',
          :node => 'Nodes',
          :mqserver => 'MsgServers',
          :dbserver => 'DBServers',
        }
      end

      def list_map
        { :broker => :brokers,
          :node => :nodes,
          :mqserver => :mqservers,
          :dbserver => :dbservers,
        }
      end

      def display_order
        advanced_mode? ? [:broker,:mqserver,:dbserver,:node] : [:broker,:node]
      end

      def roles
        @roles ||= self.role_map.keys.map{ |role| role.to_s }
      end
    end

    def initialize config, deployment
      @config = config
      @hosts = []
      if deployment.has_key?('Hosts') and not deployment['Hosts'].nil? and deployment['Hosts'].length > 0
        deployment['Hosts'].each do |host_instance|
          hosts << Installer::HostInstance.new(host_instance)
        end
      end
      dns_config = deployment.has_key?('DNS') ? deployment['DNS'] : {}
      @dns = Installer::DNSConfig.new(dns_config)
    end

    def brokers
      get_hosts_by_role :broker
    end

    def mqservers
      get_hosts_by_role :mqserver
    end

    def dbservers
      get_hosts_by_role :dbserver
    end

    def nodes
      get_hosts_by_role :node
    end

    def get_host_instance_by_hostname hostname
      host_list = @hosts.select{ |h| h.host == hostname }
      if host_list.nil? or host_list.length == 0
        return nil
      end
      host_list[0]
    end

    def add_host_instance! host_instance
      @hosts << host_instance
      update_valid_gear_sizes!
      update_district_mappings!
      save_to_disk!
    end

    def remove_host_instance! host_instance
      hosts.delete_if{ |h| h == host_instance }
      save_to_disk!
    end

    def save_to_disk!
      config.set_deployment self
      config.save_to_disk!
    end

    def set_basic_hosts!
      # Zip through the hosts, clean up the list so that all brokers also have mqserver and dbserver roles
      # Also remove standalone mqserver and dbserver hosts
      to_delete = []
      hosts.each do |host_instance|
        if host_instance.roles.include?(:broker)
          # Broker hosts (which may also contain a node) get mqserver and dbserver as well
          host_instance.roles = [:mqserver,:dbserver].concat(host_instance.roles).uniq
        elsif host_instance.roles.include?(:node)
          # Node hosts (which don't include brokers) get any other roles removed
          host_instance.roles = [:node]
        else
          # Other hosts get nuked.
          to_delete << host_instance.id
        end
      end
      if to_delete.length > 0
        hosts.delete_if{ |h| to_delete.include?(h.id) }
      end
      save_to_disk!
    end

    def is_valid?(check=:basic)
      errors = []
      # See if there's at least one of each role
      self.class.list_map.each_pair do |role,group|
        group_list = self.send(group)
        if group_list.length == 0
          return false if check == :basic
          errors << Installer::DeploymentRoleMissingException.new("There must be at least one #{role.to_s} in the deployment configuration.")
        end
      end
      # Check the host entries
      if check == :basic
        if hosts.select{ |h| h.is_valid?(check) == false }.length > 0
          return false
        end
      else
        hosts.each do |host_instance|
          errors.concat(host_instance.is_valid?(check))
        end
      end
      # Check the DNS setup
      if check == :basic
        return false if not dns.is_valid?(check)
      else
        errors.concat(dns.is_valid?(check))
      end
      return true if check == :basic
      errors
    end

    def is_advanced?
      hosts.select{ |h| not h.is_basic_broker? and not h.is_basic_node? and not h.is_all_in_one? }.length > 0
    end


    def is_valid_role_list? role
      list = self.send(self.class.list_map[role])
      return false if list.length == 0
      return false if list.select{ |h| h.is_valid? == false }.length > 0
      true
    end

    def to_hash
      { 'Hosts' => hosts.map{ |h| h.to_hash },
        'DNS' => dns.to_hash,
      }
    end

    def get_role_list role
      hosts.select{ |h| h.roles.include?(role) }
    end

    def get_node_profiles_nodes
      nodes.map {|node| node.node_profile}.compact.uniq
    end

    def get_node_profiles_all
      valid_gear_sizes = Set.new
      valid_gear_sizes.merge(get_node_profiles_nodes)
      brokers.each do |broker|
        vgs = broker.valid_gear_sizes
        valid_gear_sizes.merge(broker.valid_gear_sizes.split(',')) unless (vgs.nil? or vgs.empty?)
      end
      return valid_gear_sizes.to_a
    end

    def get_valid_gear_sizes
      node_profiles = get_node_profiles_all
      return node_profiles.empty? ? nil : node_profiles.join(',')
    end

    def update_valid_gear_sizes!
      valid_gear_sizes = get_valid_gear_sizes
      brokers.each do |broker|
        broker.valid_gear_sizes=valid_gear_sizes
      end
      save_to_disk!
    end

    def get_districts
      districts = nodes.map {|node| node.district} + brokers.map {|broker| broker.district_mappings.nil? ? nil : broker.district_mappings.keys}.flatten
      return districts.compact.uniq
    end

    def get_profile_for_district district
      brokers.each do |broker|
        unless (broker.district_mappings.nil? or broker.district_mappings.empty?)
          broker.district_mappings.each do |d,n|
            if d == district
              nodes.each do |node|
                return node.node_profile if node.host == n[0]
              end
            end
          end
        end
      end
      return nil
    end

    def update_district_mappings!
      district_mappings={}

      nodes.each do |node|
        (district_mappings[node.district] ||= []) << node.host if node.district
      end

      brokers.each do |broker|
        unless broker.district_mappings.nil? or broker.district_mappings.empty?
          district_mappings.merge(broker.district_mappings){|key, oldnodes, newnodes| oldnodes + newnodes}
        end
      end

      district_mappings.each do |district,nodes|
        district_mappings[district] = Set.new(nodes).to_a
      end

      brokers.each do |broker|
        broker.district_mappings = district_mappings unless district_mappings.empty?
      end
      save_to_disk!
    end

    def get_synchronized_attr attr
      hosts.each do |h|
        val = h.send(attr)
        if not val.nil?
          return val
        end
      end
      return nil
    end

    def set_synchronized_attr! attr, value
      hosts.each do |h|
        unless h.send(attr).nil?
          h.send("#{attr.to_s}=".to_sym, value)
        end
      end
      save_to_disk!
    end

    def get_hosts_by_role role
      hosts.select{ |h| h.roles.include?(role) }
    end

    def get_hosts_without_role role
      hosts.select{ |h| not h.roles.include?(role) }
    end

    def get_hosts_by_fqdn(fqdn)
      hosts.select{ |h| h.host == fqdn }
    end

    # A removable host is not the only host in the deployment,
    # and shares its roles with at least one other host.
    def get_removable_hosts
      return [] if hosts.length <= 1
      removable_hosts = []
      hosts.each do |host_instance|
        removable = true
        host_instance.roles.each do |role|
          next if get_hosts_by_role(role).length > 1
          removable = false
          break
        end
        if removable
          removable_hosts << host_instance
        end
      end
      removable_hosts
    end

    # An unremovable host is the only host in the deployment,
    # or a host with a role that no other host has.
    def get_unremovable_hosts
      return hosts if hosts.length == 1
      unremovable_hosts = []
      hosts.each do |host_instance|
        unremovable = false
        host_instance.roles.each do |role|
          next if get_hosts_by_role(role).length > 1
          unremovable = true
          break
        end
        if unremovable
          unremovable_hosts << host_instance
        end
      end
      unremovable_hosts
    end
  end
end
