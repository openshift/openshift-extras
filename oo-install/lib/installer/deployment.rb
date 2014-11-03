require 'installer/broker_global_config'
require 'installer/district'
require 'installer/dns_config'
require 'installer/helpers'
require 'installer/host_instance'
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
          :msgserver  => 'MsgServers',
          :dbserver   => 'DBServers',
        }
      end

      def list_map
        { :broker     => :brokers,
          :nameserver => :nameservers,
          :node       => :nodes,
          :msgserver  => :msgservers,
          :dbserver   => :dbservers,
        }
      end

      def display_order
        if advanced_mode?
          return [:broker,:nameserver,:msgserver,:dbserver,:node]
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
      broker_global_config = deployment.has_key?('Global') ? deployment['Global'] :
        { 'valid_gear_sizes' => 'small', 'user_default_gear_sizes' => 'small', 'default_gear_size' => 'small' }
      @broker_global = Installer::BrokerGlobalConfig.new(broker_global_config)
      @districts = []
      if deployment.has_key?('Districts') and not deployment['Districts'].nil? and deployment['Districts'].length > 0
        deployment['Districts'].each do |district|
          districts << Installer::District.new(district)
        end
      else
        districts << Installer::District.new({ 'name' => 'Default', 'gear_size' => 'small', 'node_hosts' => '' })
      end
    end

    def brokers
      get_hosts_by_role :broker
    end

    def nameservers
      get_hosts_by_role :nameserver
    end

    def msgservers
      get_hosts_by_role :msgserver
    end

    def dbservers
      get_hosts_by_role :dbserver
    end

    def nodes
      get_hosts_by_role :node
    end

    def load_balancers
      hosts.select{ |h| h.is_load_balancer? }
    end

    def set_load_balancer(lb_host_instance=nil,broker_cluster_virtual_ip_addr=nil,broker_cluster_virtual_host=nil)
      brokers.each do |host_instance|
        if not lb_host_instance.nil? and host_instance == lb_host_instance
          host_instance.broker_cluster_load_balancer   = true
          host_instance.broker_cluster_virtual_ip_addr = broker_cluster_virtual_ip_addr
          host_instance.broker_cluster_virtual_host    = broker_cluster_virtual_host
        else
          host_instance.broker_cluster_load_balancer   = false
          host_instance.broker_cluster_virtual_ip_addr = nil
          host_instance.broker_cluster_virtual_host    = nil
        end
      end
    end

    def unset_load_balancer
      # Calling set_load_balancer without args purges the load balancer settings completely
      set_load_balancer
    end

    def get_host_instance_by_hostname hostname
      host_list = @hosts.select{ |h| h.host == hostname }
      if host_list.nil? or host_list.length == 0
        return nil
      end
      host_list[0]
    end

    def get_district_by_node host_instance
      return nil if not host_instance.is_node?
      districts.each do |district|
        next if not district.node_hosts.include?(host_instance.host)
        return district
      end
      nil
    end

    def add_host_instance! host_instance
      @hosts << host_instance
      save_to_disk!
    end

    def remove_host_instance! host_instance
      hosts.delete_if{ |h| h == host_instance }
      save_to_disk!
    end

    def add_district! district
      @districts << district
      save_to_disk!
    end

    def remove_district! district
      districts.delete_if{ |d| d == district }
      save_to_disk!
    end

    def save_to_disk!
      config.set_deployment self
      config.save_to_disk!
    end

    def set_basic_hosts!
      # Zip through the hosts, clean up the list so that all brokers also have msgserver and dbserver roles
      # Also remove standalone msgserver and dbserver hosts
      to_delete = []
      hosts.each do |host_instance|
        dns_host = host_instance.has_role?(:nameserver)
        if host_instance.roles.include?(:broker)
          # Broker hosts (which may also contain a node and/or nameserver) get msgserver and dbserver as well
          host_instance.roles = [:msgserver,:dbserver].concat(host_instance.roles).uniq
        elsif host_instance.roles.include?(:node)
          # Node hosts (which don't include brokers) get roles other than nameserver removed
          host_instance.roles = dns_host ? [:node,:nameserver] : [:node]
        elsif dns_host
          # If the DNS host is not on a broker or node, just make sure that the
          # other roles are stripped off.
          host_instance.roles = [:nameserver]
        else
          # Other hosts get nuked.
          to_delete << host_instance.object_id
        end
      end
      if to_delete.length > 0
        hosts.delete_if{ |h| to_delete.include?(h.object_id) }
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
      if dns.deploy_dns?
        # Make sure there is one nameserver
        if nameservers.length == 0
          return false if check == :basic
          errors << Installer::DeploymentCheckFailedException.new("The installer is configured to deploy DNS, but no host has been selected as the DNS host.")
        elsif nameservers.length > 1
          return false if check == :basic
          errors << Installer::DeploymentCheckFailedException.new("Only one host can be selected as the DNS host, but the role has been assigned to: #{nameservers.sort_by{ |h| h.host }.map{ |h| h.host }.join(', ')}")
        end
        # If we are deploying DNS for the component hosts, confirm domain
        if dns.register_components? and not dns.component_domain.nil?
          seen_domains = hosts.map{ |h| get_domain_from_fqdn(h.host) }.uniq
          if seen_domains.length == 1 and not seen_domains[0] == dns.component_domain
            return false if check == :basic
            if seen_domains[0] == ''
              errors << Installer::DeploymentCheckFailedException.new("Hostname definitions are missing the domain, host definitions should be Fully Qualified Domain Names")
            else
              errors << Installer::DeploymentCheckFailedException.new("The implied host domain '#{seen_domains[0]}' does not match the specified host domain of '#{dns.component_domain}' for DNS")
            end
          elsif seen_domains.length > 1
            return false if check == :basic
            errors << Installer::DeploymentCheckFailedException.new("The OpenShift hosts are spread across multiple domains (#{seen_domains.join(', ')}), however the deployment is configured to act as DNS server for all hosts under the '#{dns.component_domain}' domain.")
          end
        end
      elsif nameservers.length > 0
        return false if check == :basic
        errors << Installer::DeploymentCheckFailedException.new("The installer is configured -not- to deploy DNS, but a host has been designated as the DNS host.")
      end
      # Check the host entries
      if hosts.select{ |h| not h.is_valid?(:basic) }.length > 0
        return false if check == :basic
        hosts.each do |host_instance|
          errors.concat(host_instance.is_valid?(check))
        end
      end
      # Confirm that all hostnames and IP addresses are unique.
      seen_hostnames = {}
      seen_ip_addrs  = {}
      hosts.each do |host_instance|
        if seen_hostnames.has_key?(host_instance.host)
          return false if check == :basic
          if seen_hostnames[host_instance.host] == 1
            errors << Installer::DeploymentCheckFailedException.new("Hostname '#{host_instance.host}' is used by multiple hosts in the deployment.")
          end
          seen_hostnames[host_instance.host] += 1
        else
          seen_hostnames[host_instance.host] = 1
        end
        if seen_ip_addrs.has_key?(host_instance.ip_addr)
          return false if check == :basic
          if seen_ip_addrs[host_instance.ip_addr] == 1
            errors << Installer::DeploymentCheckFailedException.new("IP address '#{host_instance.ip_addr}' is used by multiple hosts in the deployment.")
          end
          seen_ip_addrs[host_instance.ip_addr] += 1
        else
          seen_ip_addrs[host_instance.ip_addr] = 1
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
      # Check the account info settings
      if check == :basic
        return false if not are_accounts_valid?
      else
        errors.concat(are_accounts_valid?(check))
      end
      # Still here? Good to go.
      return true if check == :basic
      errors
    end

    def are_accounts_valid?(check=:basic)
      errors = []
      service_accounts_info.keys.each do |service_param|
        param_roles = service_accounts_info[service_param][:roles]
        seen_values = []
        hosts.each do |host_instance|
          host_value = host_instance.send(service_param)
          if (host_instance.roles & param_roles).length == 0
            # In this case, the host should not have this setting.
            next if host_value.nil?
            return false if check == :basic
            errors << Installer::HostInstanceSettingException.new("Host instance '#{host_instance.host}' should not have a value for the '#{service_param.to_s}' parameter.")
          elsif not is_valid_string?(host_value)
            return false if check == :basic
            errors << Installer::HostInstanceSettingException.new("Host instance '#{host_instance.host}' has an invalid value for the '#{service_param.to_s}' parameter.")
          else
            seen_values << host_value
          end
        end
        next if seen_values.uniq.length == 1
        return false if check == :basic
        errors << Installer::DeploymentAccountInfoMismatchException.new("The value of the '#{service_param.to_s}' parameter is not consistent across the deployment.")
      end
      return true if check == :basic
      errors
    end

    def are_districts_valid?(check=:basic)
      errors = []
      if districts.select{ |d| not d.is_valid?(:basic,nodes,broker_global) }.length > 0
        return false if check == :basic
        districts.each do |district|
          errors.concat(district.is_valid?(check,nodes,broker_global))
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
      orphaned_nodes = nodes.select{ |h| get_district_by_node(h).nil? }
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
      if (brokers.length == 1 and load_balancers.length != 0)
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("A Broker load balancer should not be provided for a single-Broker deployment.")
      end
      if (brokers.length > 1 and load_balancers.length != 1 and get_context != :ose)
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("There must be one and only one load balancer host for a multi-Broker deployment.")
      end
      if (brokers.length > 1 and get_context == :ose and
          (broker_global.broker_hostname.nil? or broker_global.broker_hostname.empty?))
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("A HA DNS entry must be configured for multiple brokers")
      end
      if (dbservers.length > 1 and not dbservers.count.odd?)
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("If configuring HA datastore hosts, then there needs to be an odd number of datastore hosts defined")
      end
      if hosts.length > 1
        nodes.each do |n|
          if n.roles.length > 1
            return false if check == :basic
            errors << Installer::DeploymentHAMisconfiguredException.new("A node must not have other roles assigned to it")
          end
        end
      end


      db_replication    = dbservers.length > 1
      seen_db_keys      = {}
      msgserver_cluster = msgservers.length > 1
      seen_msgserver_passwords = {}
      hosts.each do |host_instance|
        if host_instance.is_load_balancer?
          if not host_instance.is_broker?
            return false if check == :basic
            errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' is configured as a load balancer for an HA broker deployment, but it is not configured as a Broker.")
          end
          if host_instance.broker_cluster_virtual_ip_addr.nil? or not is_valid_ip_addr?(host_instance.broker_cluster_virtual_ip_addr)
            return false if check == :basic
            errors << Installer::HostInstanceIPAddressException.new("Host instance '#{host_instance.host}' has a missing or invalid Broker cluster virtual ip address '#{host_instance.broker_cluster_virtual_ip_addr}'.")
          end
          if host_instance.broker_cluster_virtual_host.nil? or not is_valid_hostname?(host_instance.broker_cluster_virtual_host) or host_instance.broker_cluster_virtual_host == 'localhost'
            return false if check == :basic
            errors << Installer::HostInstanceHostNameException.new("Broker cluster virtual hostname '#{host_instance.broker_cluster_virtual_host}' for Broker load-balancer host '#{ihost_instance.host}' is invalid. Note that 'localhost' is not a permitted value here.")
          end
        else
          if not host_instance.broker_cluster_virtual_ip_addr.nil?
            return false if check == :basic
            errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' has a Broker load-balancer virtual IP address set, but it is not configured as a Broker load balancer.")
          end
          if not host_instance.broker_cluster_virtual_host.nil?
            return false if check == :basic
            errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' has a Broker load-balancer virtual hostname set, but it is not configured as a Broker load balancer.")
          end
        end
        if host_instance.is_dbserver?
          if db_replication
            if host_instance.mongodb_replica_key.nil?
              return false if check == :basic
              errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' is a DB server in a DB replicated deployment, but it has an unset DB replica key value.")
            else
              seen_db_keys[host_instance.mongodb_replica_key] = 1
            end
          elsif not db_replication and not host_instance.mongodb_replica_key.nil?
            return false if check == :basic
            errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' is the only DB server in a non-replicated DB deployment, but it has a set DB replica key value.")
          end
        elsif not host_instance.mongodb_replica_key.nil?
          return false if check == :basic
          errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' has a DB replica key set, but it is not configured as a DB server.")
        end
        if host_instance.is_msgserver?
          if msgserver_cluster
            if host_instance.msgserver_cluster_password.nil?
              return false if check == :basic
              errors << Installer::HostInstanceMismatchedSettingsException.new("MsgServer instance '#{host_instance.host}' is part of a clustered MsgServer deployment, but is missing the 'msgserver_cluster_password' setting.")
            else
              seen_msgserver_passwords[host_instance.msgserver_cluster_password] = 1
            end
          elsif not host_instance.msgserver_cluster_password.nil?
            return false if check == :basic
            errors << Installer::HostInstanceMismatchedSettingsException.new("MsgServer instance '#{host_instance.host}' has a MsgServer password set, but it is not necessary to set a MsgServer password in a non-clustered MsgServer deployment.")
          end
        elsif not host_instance.msgserver_cluster_password.nil?
          return false if check == :basic
          errors << Installer::HostInstanceMismatchedSettingsException.new("Host instance '#{host_instance.host}' has a MsgServer password set, but it is not configured as a MsgServer.")
        end
      end
      if db_replication and seen_db_keys.keys.length > 1
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("The DB replication key values used on the DB server hosts do not all match. They must be identical.")
      end
      if msgserver_cluster and seen_msgserver_passwords.length > 1
        return false if check == :basic
        errors << Installer::DeploymentHAMisconfiguredException.new("The MsgServer cluster password values used on the MsgServer hosts do not all match. They must be identical.")
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

    def is_ha?
      brokers.length > 1 or msgservers.length > 1 or dbservers.length > 1
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

    def set_synchronized_attr service_param, value
      hosts.each do |host_instance|
        common_roles = service_accounts_info[service_param][:roles] & host_instance.roles
        host_value   = common_roles.length == 0 ? nil : value
        host_instance.send("#{service_param.to_s}=".to_sym, host_value)
      end
    end

    def unset_synchronized_ha_attr_by_role role
      ha_service_accounts_info.select {|k,v| v[:roles].include? role}.each do |sa_info|
        deployment.set_synchronized_ha_attr sa_info, nil
      end
    end

    def set_synchronized_ha_attr service_param, value
      hosts.each do |host_instance|
        common_roles = ha_service_accounts_info[service_param][:roles] & host_instance.roles
        host_value   = common_roles.length == 0 ? nil : value
        host_instance.send("#{service_param.to_s}=".to_sym, host_value)
      end
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
    # the Broker load balancer
    def get_removable_hosts
      return [] if hosts.length <= 1
      removable_hosts = []
      hosts.select{ |h| not h.is_load_balancer? }.each do |host_instance|
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
    def get_unremovable_hosts(with_explanation=false)
      if hosts.length == 1
        if not with_explanation
          return hosts
        else
          return [hosts[0], ["is the only host in the deployment"]]
        end
      end
      unremovable_hosts = []
      hosts.each do |host_instance|
        unremovable = false
        reasons = []
        # If this is the load balancer, but removing this host will leave the deployment
        # with only one Broker, we're okay to remove this.
        if host_instance.is_load_balancer? and brokers.length > 2
          reasons << "is the load-balancing Broker for this multi-Broker deployment"
          unremovable = true
        end
        host_instance.roles.each do |role|
          next if get_hosts_by_role(role).length > 1
          if role == :nameserver
            reasons << "is the DNS server for this deployment"
          else
            reasons << "is the only #{self.class.role_map[role].chop} in this deployment"
          end
          unremovable = true
        end
        if unremovable
          if not with_explanation
            unremovable_hosts << host_instance
          else
            unremovable_hosts << [host_instance, reasons]
          end
        end
      end
      unremovable_hosts
    end

    # A removable host whatever is left after you factor out the unremovable ones.
    def get_removable_hosts
      unremovable_hosts = get_unremovable_hosts
      hosts.select{ |h| not unremovable_hosts.include?(h) }
    end
  end
end
