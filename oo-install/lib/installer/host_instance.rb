module Installer
  class HostInstance
    include Installer::Helpers

    attr_reader :role
    attr_accessor :host, :ssh_host, :user

    def self.attrs
      %w{host ssh_host user}.map{ |a| a.to_sym }
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
      to_hash.each_pair.map{ |k,v| k.split('_').map{ |word| ['ssh'].include?(word) ? word.upcase : word.capitalize }.join(' ') + ': ' + v.to_s }.join(', ')
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
      true
    end
  end
end
