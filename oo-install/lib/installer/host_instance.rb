require 'net/ssh'

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

    def ssh_target
      @ssh_target ||= lookup_ssh_target
    end

    def get_ssh_session
      if @ssh_session.nil? or @ssh_session.closed?
        @ssh_session = Net::SSH.start(ssh_host, user, { :auth_methods => ['publickey'], :timeout => 10 })
      end
      @ssh_session
    end

    def close_ssh_session
      @ssh_session.close
    end

    # Origin version located at
    # http://stackoverflow.com/questions/3386233/how-to-get-exit-status-with-rubys-netssh-library
    # Credit to:
    # * http://stackoverflow.com/users/11811/flitzwald
    # * http://stackoverflow.com/users/73056/han
    def ssh_exec!(command, ssh=get_ssh_session)
      stdout_data = ""
      stderr_data = ""
      exit_code = nil
      exit_signal = nil
      ssh.open_channel do |channel|
        channel.exec(command) do |ch, success|
          unless success
            abort "FAILED: couldn't execute command (ssh.channel.exec)"
          end
          channel.on_data do |ch,data|
            stdout_data+=data
          end

          channel.on_extended_data do |ch,type,data|
            stderr_data+=data
          end

          channel.on_request("exit-status") do |ch,data|
            exit_code = data.read_long
          end

          channel.on_request("exit-signal") do |ch, data|
            exit_signal = data.read_long
          end
        end
      end
      ssh.loop
      { :stdout => stdout_data, :stderr => stderr_data, :exit_code => exit_code, :exit_signal => exit_signal }
    end

    def root_user?
      @root_user ||= user == 'root'
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

    private
    def lookup_ssh_target
      ssh_config = Net::SSH::Config.for(ssh_host)
      if ssh_config.has_key?(:host_name)
        return ssh_config[:host_name]
      end
      return nil
    end
  end
end
