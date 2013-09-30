module Installer
  class HostInstance
    include Installer::Helpers

    attr_reader :role
    attr_accessor :host, :port, :ssh_host, :ssh_port, :user, :messaging_port, :db_user, :db_port

    def self.attrs
      %w{host port ssh_host ssh_port user messaging_port db_user db_port}.map{ |a| a.to_sym }
    end

    def initialize role, item={}
      @role = role
      self.class.attrs.each do |attr|
        self.send("#{attr}=", (item.has_key?(attr.to_s) ? item[attr.to_s] : nil))
      end
    end

    def to_hash
      output = {}
      self.class.attrs.each do |attr|
        next if self.send(attr).nil?
        output[attr.to_s] = self.send(attr)
      end
      output
    end

    def summarize
      to_hash.each_pair.map{ |k,v| k.split('_').map{ |word| ['db','ssh'].include?(word) ? word.upcase : word.capitalize }.join(' ') + ': ' + v.to_s }.join(', ')
    end

    def is_valid?(check=:basic)
      if not is_valid_hostname_or_ip_addr?(host)
        return false if check == :basic
        raise Installer::HostInstanceHostNameException.new("Host instance host name / IP address '#{host}' in the #{role.to_s} list is invalid.")
      end
      if not is_valid_hostname_or_ip_addr?(ssh_host)
        return false if check == :basic
        raise Installer::HostInstanceHostNameException.new("Host instance host name / IP address '#{host}' in the #{role.to_s} list is invalid.")
      end
      if not is_valid_username?(user)
        return false if check == :basic
        raise Installer::HostInstanceUserNameException.new("Host instance '#{host}' in the #{group.to_s} list has an invalid user name '#{user}'.")
      end
      if role == :dbserver
        if not is_valid_port_number?(db_port)
          return false if check == :basic
          raise Installer::HostInstancePortNumberException.new("Host instance '#{host}' in the #{group.to_s} list has an invalid database port number '#{db_port.to_s}'.")
        end
        if not is_valid_username?(db_user)
          return false if check == :basic
          raise Installer::HostInstanceUserNameException.new("Host instance '#{host}' in the #{group.to_s} list has an invalid database user name '#{db_user}'.")
        end
      elsif not is_valid_port_number?(messaging_port)
        return false if check == :basic
        raise Installer::HostInstancePortNumberException.new("Host instance '#{host}' in the #{group.to_s} list has an invalid messaging port number '#{messaging_port.to_s}'.")
      end
      if role == :broker and (not is_valid_port_number?(port) or port == messaging_port)
        return false if check == :basic
        raise Installer::HostInstancePortDuplicateException.new("Host instance '#{host}' in the #{group.to_s} list is using port '#{port}' for the REST API and the messaging client.")
      end
      true
    end
  end
end
