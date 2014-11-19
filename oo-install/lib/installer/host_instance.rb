require 'net/ssh'
require 'iconv' if RUBY_VERSION == '1.8.7'

module Installer
  class HostInstance
    include Installer::Helpers

    attr_accessor :host, :ip_addr, :named_ip_addr, :ip_interface, :ssh_host,
                  :user, :roles, :install_status,
                  :mcollective_user, :mcollective_password,
                  :mongodb_broker_user, :mongodb_broker_password,
                  :mongodb_admin_user, :mongodb_admin_password,
                  :openshift_user, :openshift_password,
                  :broker_cluster_load_balancer,
                  :broker_cluster_virtual_host,
                  :broker_cluster_virtual_ip_addr,
                  :mongodb_replica_key,:mongodb_replica_name,
                  :msgserver_cluster_password, :broker_session_secret,
                  :console_session_secret, :broker_auth_salt,
                  :broker_auth_priv_key

    def self.attrs
      %w{host roles ssh_host user ip_addr named_ip_addr ip_interface
         install_status mcollective_user mcollective_password mongodb_broker_user
         mongodb_broker_password mongodb_admin_user mongodb_admin_password
         openshift_user openshift_password broker_cluster_load_balancer
         broker_cluster_virtual_host broker_cluster_virtual_ip_addr
         mongodb_replica_key mongodb_replica_name msgserver_cluster_password
         broker_session_secret console_session_secret broker_auth_salt
         broker_auth_priv_key}.map{ |a| a.to_sym }
    end

    def initialize(item={}, init_role=nil)
      @roles                        = []
      @install_status               = item.has_key?('state') ? item['state'].to_sym : :new
      @broker_cluster_load_balancer = item.has_key?('load_balancer') && item['load_balancer'].downcase == 'y'
      self.class.attrs.each do |attr|
        # Skip booleans here or their values will be nilled out
        next if [:install_status,:broker_cluster_load_balancer].include?(attr)
        value = attr == :roles ? [] : nil
        if item.has_key?(attr.to_s)
          if attr == :roles
            # Quietly ccorrect older config files by remapping 'mqserver' to 'msgserver'
            value = item[attr.to_s].map{ |role| role == 'mqserver' ? :msgserver : role.to_sym }
          else
            value = item[attr.to_s]
          end
        end
        self.send("#{attr}=", value)
      end
      if not init_role.nil?
        add_role init_role
      end
    end

    def confirm_access
      info = { :valid_access => true, :error => nil }
      begin
        result = ssh_exec!(prepare_command("command -v ip"), false, false)
        if result[:exit_code] == 0
          @ip_exec_path = result[:stdout].chomp
        else
          info[:valid_access] = false
          info[:error] = result[:stderr] unless result[:stderr].empty?
        end
      rescue Net::SSH::AuthenticationFailed, SocketError, Timeout::Error, Errno::EHOSTUNREACH => e
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
      sudo_check_result = exec_on_host!(command)
      sudo_check_result[:exit_code] == 0
    end

    def root_user?
      user == 'root'
    end

    def localhost?
      ssh_host == 'localhost'
    end

    def is_basic_broker?
      # Basic broker has three roles (and possibly also 'nameserver', but not 'node')
      is_broker? and roles.include?(:msgserver) and roles.include?(:dbserver) and not is_node?
    end

    def is_broker?
      roles.include?(:broker)
    end

    def is_basic_node?
      # This specifically checks for node hosts with no other roles (except possibly 'nameserver') For general use, call 'is_node?' instead.
      is_node? and not is_broker? and not roles.include?(:msgserver) and not roles.include?(:dbserver)
    end

    def is_all_in_one?
      is_broker? and is_node? and roles.include?(:msgserver) and roles.include?(:dbserver)
    end

    def is_node?
      roles.include?(:node)
    end

    def is_msgserver?
      roles.include?(:msgserver)
    end

    def is_dbserver?
      roles.include?(:dbserver)
    end

    def is_nameserver?
      roles.include?(:nameserver)
    end

    def is_load_balancer?
      broker_cluster_load_balancer
    end

    def has_role?(role)
      roles.include?(role)
    end

    # NOTE: HA-related validation is tested at the deployment level, not here at the
    # host instance level. Therefore do not add broker cluster or DB replication related
    # validation tests here.
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
      if not named_ip_addr.nil? and not is_valid_ip_addr?(named_ip_addr)
        return false if check == :basic
        errors << Installer::HostInstanceIPAddressException.new("Host instance '#{host}' has an invalid BIND ip address '#{ip_addr}'.")
      end
      if [:origin, :origin_vm].include?(get_context) and is_node? and not is_valid_string?(ip_interface)
        return false if check == :basic
        errors << Installer::HostInstanceIPInterfaceException.new("Host instance '#{host}' has a blank or missing ip interface setting.")
      end
      return true if check == :basic
      errors
    end

    def add_role role
      new_roles = [role]
      if role == :broker and not advanced_mode?
        new_roles << :msgserver
        new_roles << :dbserver
      end
      @roles = roles.concat(new_roles).uniq
    end

    def remove_role role
      del_roles = [role]
      if role == :broker and not advanced_mode?
        del_roles << :msgserver
        del_roles << :dbserver
      end
      @roles.delete_if{ |r| del_roles.include?(r) }
    end

    def host_type
      @host_type ||=
        begin
          type_output = exec_on_host!('export LC_CTYPE=en_US.utf8 && cat /etc/redhat-release')
          type_result = :other
          if type_output[:exit_code] == 0
            if type_output[:stdout].match(/^CentOS/)
              type_result = :centos
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
        elsif attr == :broker_cluster_load_balancer
          output['load_balancer'] = (is_load_balancer? ? 'Y' : 'N')
        else
          output[attr.to_s] = attr == :roles ? self.send(attr).map{ |r| r.to_s } : self.send(attr)
        end
      end
      output
    end

    def summarize(roles_only=false)
      display_roles = []
      Installer::Deployment.display_order.each do |role|
        next if not roles.include?(role)
        display_roles << Installer::Deployment.role_map[role].chop
      end
      if is_load_balancer?
        display_roles << 'Broker Load Balancer'
      end
      if roles_only
        return display_roles.sort.join("\n")
      end
      "#{host} (#{display_roles.sort.join(', ')})"
    end

    def ssh_target
      @ssh_target ||= lookup_ssh_target
    end

    def get_ssh_session(abort_on_error=true)
      if @ssh_session.nil? or @ssh_session.closed?
        begin
          @ssh_session = Net::SSH.start(ssh_host, user, { :auth_methods => ['publickey'], :timeout => 10, :keepalive => true, :verbose => (debug_mode? ? :debug : :fatal) })
        rescue => e
          if abort_on_error
            abort "\nSSH access to host: #{ssh_host} failed with error message: #{e.message}"
          else
            raise e
          end
        end
      end
      @ssh_session
    end

    def close_ssh_session
      @ssh_session.close unless @ssh_session.nil? or @ssh_session.closed?
    end

    def exec_on_host!(command, display_output=false)
      if localhost?
        local_exec!(prepare_command(command), display_output)
      else
        ssh_exec!(prepare_command(command), display_output)
      end
    end

    # Origin version located at
    # http://stackoverflow.com/questions/3386233/how-to-get-exit-status-with-rubys-netssh-library
    # Credit to:
    # * http://stackoverflow.com/users/11811/flitzwald
    # * http://stackoverflow.com/users/73056/han
    def ssh_exec!(command, display_output=false, abort_on_error=true)
      stdout_data = ""
      stderr_data = ""
      exit_code = nil
      exit_signal = nil
      ssh=get_ssh_session abort_on_error
      ssh.open_channel do |channel|
        channel.request_pty do |ch, pty_success|
          if pty_success
            channel.exec(command) do |ch, success|
              unless success
                abort "FAILED: couldn't execute command (ssh.channel.exec)"
              end

              channel.on_data do |ch,data|
                stdout_data+=data
                puts data if display_output
              end

              channel.on_extended_data do |ch,type,data|
                stderr_data+=data
                puts data if display_output
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
      { :stdout => force_utf8(stdout_data), :stderr => force_utf8(stderr_data), :exit_code => exit_code, :exit_signal => exit_signal }
    end

    def local_exec!(command, display_output=false)
      stdout_data = ""
      env_rubylib = ENV.delete('RUBYLIB')
      env_gem_path = ENV.delete('GEM_PATH')
      IO.popen(command) do |pipe|
        pipe.each do |line|
          stdout_data += line
          puts line if display_output
        end
      end
      result = $?
      exit_code = result.exitstatus
      success = result.success?
      ENV['RUBYLIB'] = env_rubylib
      ENV['GEM_PATH'] = env_gem_path
      { :stdout => force_utf8(stdout_data), :exit_code => exit_code, :success => success }
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
      formatted = "PATH=${PATH}:#{ADMIN_PATHS} #{command}"
      if not root_user?
        if not localhost?
          formatted = "sudo sh -c \'#{formatted}\'"
        else
          formatted = "sudo sh -c '#{formatted}'"
        end
      end
      formatted
    end

    private

    def force_utf8(s)
      case RUBY_VERSION
        when '1.8.7' then ::Iconv.conv('UTF-8//IGNORE', 'UTF-8', s.to_s + ' ')[0..-2]
        else s.to_s.encode('UTF-8', { :invalid => :replace, :undef => :replace, :replace => '?' })
      end
    end

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
