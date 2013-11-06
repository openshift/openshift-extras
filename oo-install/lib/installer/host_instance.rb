require 'net/ssh'

module Installer
  class HostInstance
    include Installer::Helpers

    attr_accessor :id, :host, :ip_addr, :ip_interface, :ssh_host, :user, :roles

    def self.attrs
      %w{host roles ssh_host user ip_addr ip_interface}.map{ |a| a.to_sym }
    end

    def initialize(item={}, init_role=nil)
      @id = self.__id__
      @roles = []
      self.class.attrs.each do |attr|
        value = attr == :roles ? [] : nil
        if item.has_key?(attr.to_s)
          if attr == :roles
            value = item[attr.to_s].map{ |role| role == 'msgserver' ? :mqserver : role.to_sym }
          else
            value = item[attr.to_s]
          end
        end
        self.send("#{attr}=", value)
      end
      if not init_role.nil?
        @roles = @roles.concat([init_role.to_sym]).uniq
      end
    end

    def has_valid_access?
      begin
        result = ssh_exec!("command -v ip")
        if result[:exit_code] == 0
          @ip_exec_path = result[:stdout].chomp
          return true
        end
        return false
      rescue Net::SSH::AuthenticationFailed, SocketError, Timeout::Error => e
        return false
      end
    end

    def root_user?
      user == 'root'
    end

    def localhost?
      ssh_host == 'localhost'
    end

    def is_broker?
      roles.include?(:broker)
    end

    def is_node?
      roles.include?(:node)
    end

    def is_valid?(check=:basic)
      if not is_valid_hostname?(host)
        return false if check == :basic
        raise Installer::HostInstanceHostNameException.new("Host instance host name '#{host}' is invalid.")
      end
      if not is_valid_hostname?(ssh_host)
        return false if check == :basic
        raise Installer::HostInstanceHostNameException.new("Host instance SSH host name '#{host}' is invalid.")
      end
      if not is_valid_username?(user) or (localhost? and not user == `whoami`.chomp)
        return false if check == :basic
        raise Installer::HostInstanceUserNameException.new("Host instance '#{host}' has an invalid user name '#{user}'.")
      end
      if roles.length == 0
        return false if check == :basic
        raise Installer::HostInstanceUnassignedException.new("Host instance '#{host}' is not configured to any OpenShift roles.")
      end
      if not roles.length == roles.uniq.length
        return false if check == :basic
        raise Installer::HostInstanceDuplicateRoleException.new("Host instance '#{host}' has been assigned to the same role multiple times.")
      end
      if (is_broker? or is_node?) and not is_valid_ip_addr?(ip_addr)
        return false if check == :basic
        raise Installer::HostInstanceIPAddressException.new("Host instance '#{host}' has an invalid ip address '#{ip_addr}'.")
      end
      if [:origin, :origin_vm].include?(get_context) and is_node? and not is_valid_string?(ip_interface)
        return false if check == :basic
        raise Installer::HostInstanceIPInterfaceException.new("Host instance '#{host}' has a blank or missing ip interface setting.")
      end
      true
    end

    def add_role role
      @roles = roles.concat([role]).uniq
    end

    def remove_role role
      @roles.delete_if{ |r| r == role }
    end

    def host_type
      @host_type ||=
        begin
          type_output = exec_on_host!('cat /etc/redhat-release')
          type_result = :other
          if type_output[:exit_code] == 0
            if type_output[:stdout].match(/^Fedora/)
              type_result = :fedora
            elsif type_output[:stdout].match(/^Red Hat Enterprise Linux/)
              type_result = :rhel
            end
          end
          type_result
        end
    end

    def to_hash
      output = {}
      self.class.attrs.each do |attr|
        next if self.send(attr).nil?
        output[attr.to_s] = attr == :roles ? self.send(attr).map{ |r| r.to_s } : self.send(attr)
      end
      output
    end

    def summarize
      display_roles = []
      Installer::Deployment.display_order.each do |role|
        next if not roles.include?(role)
        display_roles << Installer::Deployment.role_map[role].chop
      end
      "#{host} (#{display_roles.join(', ')})"
    end

    def ssh_target
      @ssh_target ||= lookup_ssh_target
    end

    def get_ssh_session
      if @ssh_session.nil? or @ssh_session.closed?
        @ssh_session = Net::SSH.start(ssh_host, user, { :auth_methods => ['publickey'], :timeout => 10, :verbose => (debug_mode? ? :debug : :fatal) })
      end
      @ssh_session
    end

    def close_ssh_session
      @ssh_session.close
    end

    def exec_on_host!(command)
      if localhost?
        local_exec!(command)
      else
        ssh_exec!(command)
      end
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

    def local_exec!(command)
      stdout_data = %x[#{command}]
      exit_code = $?.exitstatus
      { :stdout => stdout_data, :exit_code => exit_code }
    end

    def get_ip_addr_choices
      # Grab all IPv4 addresses
      command = "#{ip_exec_path} addr list | grep inet | egrep -v inet6"
      result = exec_on_host!(command)
      if not result[:exit_code] == 0
        puts "Could not determine IP address options for #{host}."
        return []
      end

      # Search each line of the output for the IP addr and interface ID
      ip_map = []
      result[:stdout].split(/\n/).each do |line|
        # Get the first valid, non-loopback, non netmask address.
        ip_addr = line.split(/[\s\:\/]/).select{ |v| v.match(VALID_IP_ADDR_RE) and not v == "127.0.0.1" and not v.split('.')[0].to_i == 255 and not v.split('.')[-1].to_i == 255 }[0]
        next if ip_addr.nil?
        interface = line.split(/\s/)[-1]
        ip_map << [interface, ip_addr]
      end
      ip_map
    end

    def set_ip_exec_path(path)
      @ip_exec_path = path
    end

    private
    def lookup_ssh_target
      ssh_config = Net::SSH::Config.for(ssh_host)
      if ssh_config.has_key?(:host_name)
        return ssh_config[:host_name]
      end
      return nil
    end

    def ip_exec_path
      @ip_exec_path
    end
  end
end
