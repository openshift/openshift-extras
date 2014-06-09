require 'installer/helpers'
require 'installer/host_instance'
require 'installer/dns_config'
require 'installer/broker_global_config'
require 'set'

module Installer
  class Deployment
    include Installer::Helpers

    attr_reader :config
    attr_accessor :dns, :hosts, :broker_global, :districts

    class << self
      def role_map
        { :broker     => 'Brokers',
          :nameserver => 'NameServers',
          :node       => 'Nodes',
          :mqserver   => 'MsgServers',
          :dbserver   => 'DBServers',
        }
      end

      def list_map
        { :broker     => :brokers,
          :nameserver => :nameservers,
          :node       => :nodes,
          :mqserver   => :mqservers,
          :dbserver   => :dbservers,
        }
      end

      def display_order
        if advanced_mode?
          return [:broker,:nameserver,:mqserver,:dbserver,:node]
        end
        [:broker,:nameserver,:node]
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
      broker_global_config = deployment.has_key?('Global') ? deployment['Global'] : {}
      @broker_global = Installer::BrokerGlobalConfig.new(broker_global_config)
      @districts = []
      if deployment.has_key?('Districts') and not deployment['Districts'].nil? and deployment['Districts'].length > 0
        deployment['Districts'].each do |district|
          districts << Installer::District.new(district)
        end
      end
    end

    def brokers
      get_hosts_by_role :broker
    end

    def nameservers
      get_hosts_by_role :nameserver
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
        dns_host = host_instance.has_role?(:nameserver)
        if host_instance.roles.include?(:broker)
          # Broker hosts (which may also contain a node) get mqserver and dbserver as well
          host_instance.roles = [:mqserver,:dbserver].concat(host_instance.roles).uniq
        elsif host_instance.roles.include?(:node)
          # Node hosts (which don't include brokers) get any other roles removed
          host_instance.roles = dns_host ? [:node,:nameserver] : [:node]
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
      # Check the DNS setup
      if check == :basic
        return false if not dns.is_valid?(check)
      else
        errors.concat(dns.is_valid?(check))
      end
      # See if there's at least one of each role
      self.class.list_map.each_pair do |role,group|
        group_list = self.send(group)
        if group_list.length == 0
          if role == :nameserver and not dns.deploy_dns?
            next
          end
          return false if check == :basic
          errors << Installer::DeploymentRoleMissingException.new("There must be at least one #{role.to_s} in the deployment configuration.")
        end
      end
      # Check the host entries
      if hosts.select{ |h| not h.is_valid?(:basic) }.length > 0
        return false if check == :basic
        hosts.each do |host_instance|
          errors.concat(host_instance.is_valid?(check))
        end
      end
      # Check the HA settings
      if check == :basic
        return false if not is_ha_valid?(check)
      else
        errors.concat(is_ha_valid?(check))
      end
      # Check the Broker global config settings
      if check == :basic
        return false if not broker_global.is_valid?(check)
      else
        errors.concat(broker_global.is_valid?(check))
      end
      # Check the district settings
      if check == :basic
        return false if not are_districts_valid?
      else
        errors.concat(are_districts_valid?(check))
      end
      # Still here? Good to go.
      return true if check == :basic
      errors
    end

    def are_districts_valid?(check=:basic)
      errors = []
      if districts.select{ |d| not d.is_valid?(:basic,nodes,broker_global) }.length > 0
        return false if check == :basic
        districts.each do |district|
          errors.concat(district.is_valid?(check),nodes,broker_global)
        end
      end
      # Make sure no Nodes are in more than one district
      district_nodes = {}
      found_dupes    = {}
      districts.each do |district|
        district.node_hosts.each do |node_hostname|
          if district_nodes.has_key?(node_hostname) and not found_dupes.has_key?(node_hostname)
            return false if check == :basic
            errors << Installer::DistrictSettingsException.new("Node host '#{node_hostname}' is associated with multiple districts.")
            district_nodes[node_hostname] = 1
            found_dupes[node_hostname] = 1
          end
        end
      end
      # Make sure every node is in a district.
      orphaned_nodes = nodes.select{ |h| not district_nodes.has_key?(host_instance.host) }
      if orphaned_nodes.length > 0
        return false if check == :basic
        orphaned_nodes.each do |host_instance|
          errors << Installer::DistrictSettingsException.new("Node host '#{host_instance.host}' is not associated with a district.")
        end
      end
      return true if check == :basic
      errors
    end

    def is_ha_valid?(check=:basic)
      errors = []
      if not is_ha?
        return true if check == :basic
        return errors
      end
      load_balancers = hosts.select{ |h| h.is_load_balancer? }
      db_replica_primaries = hosts.select{ |h| h.is_db_replica_primary? }
      if (brokers.length == 1 and load_balancer.length != 0) or (brokers.length > 1 and load_balancers.length != 1)
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("There must be one and only one load balancer host for a multi-Broker deployment.")
      end
      if (dbservers.length == 1 and db_replica_primaries.length != 0) or (dbservers.length > 1 and db_replica_primaries.length != 1)
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("There must be one and only one datastore replica primary for a replicated datastore deployment.")
      end
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

    def is_ha?
      brokers.length > 0 or mqservers.length > 0 or dbservers.length > 0
    end

    def to_hash
      { 'Hosts'     => hosts.map{ |h| h.to_hash },
        'DNS'       => dns.to_hash,
        'Global'    => broker_global.to_hash,
        'Districts' => districts.map{ |d| d.to_hash },
      }
    end

    def get_role_list role
      hosts.select{ |h| h.roles.include?(role) }
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
    # shares its roles with at least one other host, and is not
    # the Broker load balancer or the DB replica primary
    def get_removable_hosts
      return [] if hosts.length <= 1
      removable_hosts = []
      hosts.select{ |h| not h.is_load_balancer? and not h.is_db_replica_primary? }.each do |host_instance|
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
        if host_instance.is_load_balancer? or host_instance.is_db_replica_primary?
          unremovable = true
        else
          host_instance.roles.each do |role|
            next if get_hosts_by_role(role).length > 1
            unremovable = true
            break
          end
        end
        if unremovable
          unremovable_hosts << host_instance
        end
      end
      unremovable_hosts
    end
  end
end
