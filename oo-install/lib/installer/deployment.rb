require 'installer/helpers'

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
      if deployment.has_key?('Hosts')
        deployment['Hosts'].each do |host_instance|
          hosts << Installer::HostInstance.new(host_instance)
        end
      end
      set_dns(deployment.has_key?('DNS') ? deployment['DNS'] : {})
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

    def add_host_instance! host_instance
      @hosts << host_instance
      save_to_disk!
    end

    def update_host_instance! host_instance
      @hosts[@hosts.index{ |h| h.id == host_instance.id }] = host_instance
      save_to_disk!
    end

    def remove_host_instance! id
      hosts.delete_if{ |h| h.id == id }
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

    def is_complete?
      self.class.list_map.values.each do |group|
        if self.send(group).length == 0
          return false
        end
      end
      if not dns.has_key?('app_domain')
        return false
      end
      true
    end

    def is_valid?(check=:basic)
      # Check the host list
      if hosts.select{ |h| h.is_valid?(check) == false }.length > 0
        return false
      end
      [:broker, :mqserver, :dbserver].each do |role|
        if not hosts.select{ |h| h.roles.include?(role) }.length == 1
          return false
        end
      end
      # Check the DNS setup
      if not dns.has_key?('app_domain') or not is_valid_domain?(dns['app_domain'])
        return false if check == :basic
      end
      true
    end

    def is_valid_role_list? role
      list = self.send(self.class.list_map[role])
      return false if list.length == 0
      return false if list.select{ |h| h.is_valid? == false }.length > 0
      true
    end

    def to_hash
      { 'Hosts' => hosts.map{ |h| h.to_hash },
        'DNS' => dns,
      }
    end

    def get_role_list role
      hosts.select{ |h| h.roles.include?(role) }
    end

    def set_dns dns
      @dns = dns
    end

    private
    def get_hosts_by_role role
      hosts.select{ |h| h.roles.include?(role) }
    end
  end
end
