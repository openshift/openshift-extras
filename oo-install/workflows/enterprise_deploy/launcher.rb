#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'

SOCKET_IP_ADDR = 3
VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')

# Check ENV for an alternate config file location.
@config_file = ENV['OO_INSTALL_CONFIG_FILE'] || ENV['HOME'] + '/.openshift/oo-install-cfg.yml'

@ssh_cmd = 'ssh'
@scp_cmd = 'scp'
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
  @ssh_cmd = 'ssh -v'
  @scp_cmd = 'scp -v'
end

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
@target_node_hostname = ARGV[0]
@target_node_ssh_host = nil

def env_backup
  @env_backup ||= ENV.clone
end

def clear_env
  env_backup
  ENV.delete_if{ |name,value| not name.nil? }
end

def restore_env
  env_backup.each_pair do |name,value|
    ENV[name] = value
  end
end

def components_list host_instance
  values = []
  host_instance['roles'].each do |role|
    @role_map[role].each do |ose_role|
      values << ose_role['component']
    end
  end
  values.join(',')
end

# SOURCE for which:
# http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each { |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable? exe
    }
  end
  return nil
end

# Back-ported from:
# http://www.ruby-doc.org/stdlib-1.9.3/libdoc/shellwords/rdoc/Shellwords.html
# ...to support running the installer w/ Ruby 1.8.7
def shellescape(str)
  # An empty argument will be skipped, so return empty quotes.
  return "''" if str.empty?

  str = str.dup

  # Treat multibyte characters as is.  It is caller's responsibility
  # to encode the string in the right encoding for the shell
  # environment.
  str.gsub!(/([^A-Za-z0-9_\-.,:\/@\n])/, "\\\\\\1")

  # A LF cannot be escaped with a backslash because a backslash + LF
  # combo is regarded as line continuation and simply ignored.
  str.gsub!(/\n/, "'\n'")

  return str
end

# Default and baked-in config values for the openshift.sh deployment
@env_map = { 'CONF_INSTALL_COMPONENTS' => 'all' }

# These values will be passed in the shim file
@env_input_map = {
  'subscription_type' => ['CONF_INSTALL_METHOD'],
  'repos_base' => ['CONF_REPOS_BASE'],
  'os_repo' => ['CONF_RHEL_REPO'],
  'jboss_repo_base' => ['CONF_JBOSS_REPO_BASE'],
  'os_optional_repo' => ['CONF_RHEL_OPTIONAL_REPO'],
  'scl_repo' => ['CONF_RHSCL_REPO_BASE'],
  'rh_username' => ['CONF_SM_REG_NAME','CONF_RHN_REG_NAME'],
  'rh_password' => ['CONF_SM_REG_PASS','CONF_RHN_REG_PASS'],
  'sm_reg_pool' => ['CONF_SM_REG_POOL'],
  'rhn_reg_actkey' => ['CONF_RHN_REG_ACTKEY'],
}

# Pull values that may have been passed on the command line into the launcher
@env_input_map.each_pair do |input,target_list|
  env_key = "OO_INSTALL_#{input.upcase}"
  if ENV.has_key?(env_key)
    target_list.each { |target| @env_map[target] = ENV[env_key] }
  end
end

@utility_install_order = ['named','datastore','activemq','broker','node']

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'broker' => [
    { 'component' => 'broker', 'env_hostname' => 'CONF_BROKER_HOSTNAME', 'env_ip_addr' => 'CONF_BROKER_IP_ADDR' },
    { 'component' => 'named', 'env_hostname' => 'CONF_NAMED_HOSTNAME', 'env_ip_addr' => 'CONF_NAMED_IP_ADDR' },
  ],
  'node' => [{ 'component' => 'node', 'env_hostname' => 'CONF_NODE_HOSTNAME', 'env_ip_addr' => 'CONF_NODE_IP_ADDR' }],
  'mqserver' => [{ 'component' => 'activemq', 'env_hostname' => 'CONF_ACTIVEMQ_HOSTNAME' }],
  'dbserver' => [{ 'component' => 'datastore', 'env_hostname' => 'CONF_DATASTORE_HOSTNAME' }],
}

# Will map hosts to roles
@hosts = {}

# Grab the config file contents
config = YAML.load_file(@config_file)

# Set values from deployment configuration
@seen_roles = {}
if config.has_key?('Deployment') and config['Deployment'].has_key?('Hosts') and config['Deployment'].has_key?('DNS')
  config_hosts = config['Deployment']['Hosts']
  config_dns = config['Deployment']['DNS']

  named_hosts = []
  config_hosts.each do |host_info|
    # Basic config file sanity check
    %w[ ssh_host host user roles ip_addr ].each do |attr|
      next if not host_info[attr].nil?
      puts "One of the hosts in the configuration is missing the '#{attr}' setting. Exiting."
      exit 1
    end

    # Save the fqdn:ipaddr for potential named use
    named_hosts << "#{host_info['host']}:#{host_info['ip_addr']}"

    # Map hosts by ssh alias
    @hosts[host_info['ssh_host']] = host_info

    # Set up the OSE-related ENV variables
    host_info['roles'].each do |role|
      if not @seen_roles.has_key?(role)
        @seen_roles[role] = 1
      elsif not role == 'node'
        puts "Error: The #{role} role has been assigned to multiple hosts. This is not currently supported. Exiting."
        exit 1
      end

      if role == 'node'
        if @target_node_hostname == host_info['host']
          @target_node_ssh_host = host_info['ssh_host']
        end
        # Bail out if this is a node; we'll come back to nodes later.
        break
      end

      @role_map[role].each do |ose_cfg|

        # Get the rest of the OSE-role-specific settings
        @env_map[ose_cfg['env_hostname']] = host_info['host']
        if ose_cfg.has_key?('env_ip_addr')
          @env_map[ose_cfg['env_ip_addr']] = host_info['ip_addr']
        end
      end
    end
  end

  # DNS settings
  @env_map['CONF_DOMAIN'] = config_dns['app_domain']
  if config_dns.has_key?('register_components') and config_dns['register_components'] == 'yes'
    if not config_dns.has_key?('component_domain')
      puts "Error: The config specifies registering OpenShift component hosts with OpenShift DNS, but no OpenShift component host domain has been specified. Exiting."
      exit 1
    end
    @env_map['CONF_HOSTS_DOMAIN'] = config_dns['component_domain']
    @env_map['CONF_NAMED_ENTRIES'] = named_hosts.join(',')
  else
    @env_map['CONF_HOSTS_DOMAIN'] = config_dns['app_domain']
    @env_map['CONF_NAMED_ENTRIES'] = 'NONE'
  end
end

if @hosts.empty?
  puts "The config file at #{@config_file} does not contain OpenShift deployment information. Exiting."
  exit 1
end

if not @target_node_hostname.nil? and @target_node_ssh_host.nil?
  puts "The list of nodes in the config file at #{@config_file} does not contain an entry for #{@target_node_hostname}. Exiting."
  exit 1
end

# Make sure the per-host config is legit
@hosts.each_pair do |ssh_host,info|
  roles = info['roles']
  duplicate = roles.detect{ |e| roles.count(e) > 1 }
  if not duplicate.nil?
    puts "Multiple instances of role type '#{@role_map[duplicate]['role']}' are specified for installation on the same target host (#{ssh_host}).\nThis is not a valid configuration. Exiting."
    exit 1
  end
  if not @target_node_hostname.nil? and @target_node_ssh_host == ssh_host and (roles.length > 1 or not roles[0] == 'node')
    puts "The specified node to be added also contains other OpenShift components.\nNodes can only be added as standalone components on their own systems. Exiting."
    exit 1
  end
end

# Set the installation order
host_order = []
@utility_install_order.each do |order_role|
  next if not order_role == 'node' and not @target_node_ssh_host.nil?
  @hosts.each_pair do |ssh_host,host_info|
    host_info['roles'].each do |host_role|
      @role_map[host_role].each do |ose_info|
        if ose_info['component'] == order_role
          next if not @target_node_ssh_host.nil? and not @target_node_ssh_host == ssh_host
          host_order << ssh_host unless host_order.include?(ssh_host)
        end
      end
    end
  end
end

# Summarize the plan
if @target_node_ssh_host.nil?
  puts "Preparing to install OpenShift Enterprise on the following hosts:\n"
else
  puts "Preparing to add this node to an OpenShift Enterprise system:\n"
end
host_order.each do |ssh_host|
  puts "  * #{ssh_host}: #{@hosts[ssh_host]['roles'].join(', ')}\n"
end

# Run the jobs
@child_pids = []
saw_deployment_error = false
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['user']
  host = @hosts[ssh_host]['host']
  hostfile = "oo_install_configure_#{host}.sh"
  @env_map['CONF_INSTALL_COMPONENTS'] = components_list(@hosts[ssh_host])

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @env_map[@role_map['node'][0]['env_hostname']] = @hosts[ssh_host]['host']
    @env_map[@role_map['node'][0]['env_ip_addr']] = @hosts[ssh_host]['ip_addr']
  else
    @env_map.delete(@role_map['node'][0]['env_hostname'])
    @env_map.delete(@role_map['node'][0]['env_ip_addr'])
  end

  # Write the openshift.sh settings to a launcher script and gratuitously escape everything
  filetext = ''
  @env_map.each_pair do |env,val|
    filetext << "export #{env}=#{shellescape(val)}\n"
  end
  filetext << "/tmp/openshift.sh |& tee -a /tmp/openshift-install.log\n"
  filetext << "rm -f /tmp/openshift.sh /tmp/#{hostfile}\n"
  filetext << "exit\n"

  # Save it out so we can copy it to the target
  hostfilepath = "/tmp/#{hostfile}"
  if File.exists?(hostfilepath)
    File.unlink(hostfilepath)
  end
  fh = File.new(hostfilepath, 'w')
  fh.write(filetext)
  fh.close

  # Handle the config file copying and delete the original.
  if not ssh_host == 'localhost'
    puts "Copying deployment scripts to target #{ssh_host}.\n"
    system "#{@scp_cmd} #{hostfilepath} #{user}@#{ssh_host}:#{hostfilepath}"
    if not $?.exitstatus == 0
      puts "Could not copy deployment configuration file to remote host. Exiting."
      saw_deployment_error = true
      break
    end
    system "#{@scp_cmd} #{File.dirname(__FILE__)}/openshift.sh #{user}@#{ssh_host}:/tmp/"
    if not $?.exitstatus == 0
      puts "Could not copy deployment utility to /tmp on remote host. Exiting."
      saw_deployment_error = true
      break
    end
  else
    # localhost; relocate launcher file
    system "cp #{File.dirname(__FILE__)}/openshift.sh /tmp/"
    system "chmod u+x #{hostfilepath} /tmp/openshift.sh"
  end

  puts "Running deployment on #{host}\n"

  @child_pids << Process.fork do
    sudo = user == 'root' ? '' : 'sudo '
    exit_code = 0
    if not ssh_host == 'localhost'
      system "#{@ssh_cmd} #{user}@#{ssh_host} '#{sudo}chmod u+x /tmp/#{hostfile} /tmp/openshift.sh \&\& #{sudo}/tmp/#{hostfile}'"
    else
      # Set up the command before we dump ENV
      command = "bash -l -c '#{sudo}/tmp/#{hostfile}'"

      # Local installation. Clean out the ENV.
      clear_env

      # Run the launcher
      system command
      exit_code = $?.exitstatus

      # Now restore the original env
      restore_env
    end

    # Now we can safely remove the config file
    if File.exists?(hostfilepath)
      File.unlink(hostfilepath)
    end

    # Leave the fork
    exit exit_code
  end
  puts "Installation completed for host #{host}\n"
end

procs = Process.waitall

# on total success...
puts "Please reboot installed systems to complete deployment."

exit
