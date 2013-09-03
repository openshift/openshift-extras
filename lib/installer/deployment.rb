require 'installer/helpers'

module Installer
  class Deployment
    attr_reader :config
    attr_accessor :brokers, :nodes, :mqservers, :dbservers

    def self.role_map
      { :broker => 'Brokers',
        :node => 'Nodes',
        :mqserver => 'MQServers',
        :dbserver => 'DBServers',
      }
    end

    def initialize config, deployment
      @config = config
      self.class.role_map.each_pair do |role, hkey|
        set_role_list role, (deployment.has_key?(hkey) ? deployment[hkey].map{ |i| Installer::System.new(role, i) } : [])
      end
    end

    def add_system role, item
      list = get_role_list role
      if item.is_a?(Installer::System)
        if item.role == role
          list << item
        else
          raise Installer::SystemRoleIncompatibleException.new("Tried to add a system of role #{item.role} to the #{role.to_s} list")
        end
      else
        list << Installer::System.new(role, item)
      end
      set_role_list role, list
      save_to_disk
    end

    def remove_system role, index
      list = get_role_list role
      list.delete_at(index)
      set_role_list role, list
    end

    def to_hash
      { 'Brokers' => brokers.map{ |b| b.to_hash },
        'Nodes' => nodes.map{ |n| n.to_hash },
        'MQServers' => mqservers.map{ |m| m.to_hash },
        'DBServers' => dbservers.map{ |d| d.to_hash },
      }
    end

    def save_to_disk
      config.set_deployment self
      config.save_to_disk
    end

    def get_role_list role
      listname = "#{role.to_s}s".to_sym
      self.send(listname)
    end

    def set_role_list role, list
      listname = "#{role.to_s}s".to_sym
      self.send("#{listname}=", list)
    end
  end

  class System
    include Installer::Helpers

    attr_reader :role
    attr_accessor :host, :port, :ssh_port, :user, :messaging_port, :db_user

    def self.attrs
      %w{host port ssh_port user messaging_port db_user}.map{ |a| a.to_sym }
    end

    def initialize role, item={}
      @role = role
      self.class.attrs.each do |attr|
        self.send("#{attr}=", (item.has_key?(attr.to_s) ? item[attr.to_s] : nil))
      end
    end

    def to_hash
      Hash[self.class.attrs.map{ |attr| self.send(attr).nil? ? [] : [attr.to_s, self.send(attr)] }]
    end

    def summarize
      to_hash.each_pair.map{ |k,v| k.split('_').map{ |word| ['db','ssh'].include?(word) ? word.upcase : word.capitalize }.join(' ') + ': ' + v.to_s }.join(', ')
    end

    def valid?
      unless is_valid_hostname_or_ip_addr?(host) and is_valid_username?(user)
        return false
      end
      if role == :dbserver and (not is_valid_port_number?(db_port) or not is_valid_username?(db_user))
        return false
      end
      if role != :dbserver and not is_valid_port_number?(messaging_port)
        return false
      end
      if role == :broker and (not is_valid_port_number?(port) or port == messaging_port)
        return false
      end
      true
    end
  end
end
