require 'net/ssh'

module Installer
  class HostInstance
    include Installer::Helpers

    attr_accessor :host, :ip_addr, :ip_interface, :ssh_host, :user, :roles, :install_status

    def self.attrs
      %w{host roles ssh_host user ip_addr ip_interface install_status}.map{ |a| a.to_sym }
    end

    def initialize(item={}, init_role=nil)
      @roles = []
      @install_status = item.has_key?('state') ? item['state'].to_sym : :new
      self.class.attrs.each do |attr|
        # Skip install_status here or the value will be nilled out
        next if attr == :install_status
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

    def confirm_access
      info = { :valid_access => true, :error => nil }
      begin
        result = ssh_exec!(prepare_command("command -v ip"))
        if result[:exit_code] == 0
          @ip_exec_path = result[:stdout].chomp
        else
          info[:valid_access] = false
        end
      rescue Net::SSH::AuthenticationFailed, SocketError, Timeout::Error => e
        info[:valid_access] = false
        info[:error] = e
      end
      info
    end

    def is_new?
      @install_status == :new
    end

    def is_installing?
      not [:new,:completed,:validated,:failed].include?(@install_status)
    end

    def is_failed?
      @install_status == :failed
    end

    def is_installed?
      @install_status == :completed
    end

    def is_install_validated?
      @install_status == :validated
    end

    def can_sudo_execute? util
      command = "sudo -l #{util}"
      sudo_check_result = {}
      if localhost?
        sudo_check_result = local_exec!(command)
      else
        sudo_check_result = ssh_exec!(command)
      end
      sudo_check_result[:exit_code] == 0
    end

    def root_user?
      user == 'root'
    end

    def localhost?
      ssh_host == 'localhost'
    end

    def is_basic_broker?
      # Basic broker has three roles
      roles.length == 3 and roles.include?(:broker) and roles.include?(:mqserver) and roles.include?(:dbserver)
    end

    def is_basic_node?
      # This specifically checks for node hosts with no other roles. For general use, call 'is_node?' instead.
      roles.length == 1 and roles[0] == :node
    end

    def is_all_in_one?
      roles.length == 4 and roles.include?(:broker) and roles.include?(:mqserver) and roles.include?(:dbserver) and roles.include?(:node)
    end

    def is_node?
      roles.include?(:node)
    end

    def is_valid?(check=:basic)
      errors = []
      if not is_valid_hostname?(host) or host == 'localhost'
        return false if check == :basic
        errors << Installer::HostInstanceHostNameException.new("Host instance host name '#{host}' is invalid. Note that 'localhost' is not a permitted value here.")
      end
      if not is_valid_hostname?(ssh_host)
        return false if check == :basic
        errors << Installer::HostInstanceHostNameException.new("Host instance SSH host name '#{host}' is invalid.")
      end
      if not is_valid_username?(user) or (localhost? and not user == `whoami`.chomp)
        return false if check == :basic
        errors << Installer::HostInstanceUserNameException.new("Host instance '#{host}' has an invalid user name '#{user}'.")
      end
      if roles.length == 0
        return false if check == :basic
        errors << Installer::HostInstanceUnassignedException.new("Host instance '#{host}' is not configured to any OpenShift roles.")
      end
      if not roles.length == roles.uniq.length
        return false if check == :basic
        errors << Installer::HostInstanceDuplicateRoleException.new("Host instance '#{host}' has been assigned to the same role multiple times.")
      end
      if not is_valid_ip_addr?(ip_addr)
        return false if check == :basic
        errors << Installer::HostInstanceIPAddressException.new("Host instance '#{host}' has an invalid ip address '#{ip_addr}'.")
      end
      if [:origin, :origin_vm].include?(get_context) and is_node? and not is_valid_string?(ip_interface)
        return false if check == :basic
        errors << Installer::HostInstanceIPInterfaceException.new("Host instance '#{host}' has a blank or missing ip interface setting.")
      end
      return true if check == :basic
      errors
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
        if attr == :install_status
          output['state'] = self.send(attr).to_s
        else
          output[attr.to_s] = attr == :roles ? self.send(attr).map{ |r| r.to_s } : self.send(attr)
        end
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
        local_exec!(prepare_command(command))
      else
        ssh_exec!(prepare_command(command))
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
        channel.request_pty do |ch, pty_success|
          if pty_success
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
          else
            abort "FAILED: couldn't establish shell"
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

    def prepare_command command
      formatted = String.new(command)
      if not root_user?
        if not localhost?
          formatted = "sudo sh -c \'#{command}\'"
        else
          formatted = "sudo sh -c '#{command}'"
        end
      end
      formatted
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
