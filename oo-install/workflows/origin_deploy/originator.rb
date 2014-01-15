#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'

SOCKET_IP_ADDR = 3
VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')
@puppet_module_name = 'openshift/openshift_origin'
@puppet_module_ver = '3.0.1'

# Check ENV for an alternate config file location.
if ENV.has_key?('OO_INSTALL_CONFIG_FILE')
  @config_file = ENV['OO_INSTALL_CONFIG_FILE']
else
  @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# Check to see if we need to preserve generated files.
@keep_assets = ENV.has_key?('OO_INSTALL_KEEP_ASSETS') and ENV['OO_INSTALL_KEEP_ASSETS'] == 'true'

@ssh_cmd = 'ssh -t -q'
@scp_cmd = 'scp -q'
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
  @ssh_cmd = 'ssh -t -v'
  @scp_cmd = 'scp -v'
end

def env_backup
  @env_backup ||= ENV.to_hash
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

def is_older_puppet_module(version)
  # Knock out the easy comparison first
  return false if version == @puppet_module_ver

  target = @puppet_module_ver.split('.')
  comp = version.split('.')
  for i in 0..(target.length - 1)
    if comp[i].nil? or comp[i].to_i < target[i].to_i
      # Comp ran out of numbers before target or
      # current comp version number is less than
      # target version number: target is newer.
      return true
    elsif comp[i].to_i > target[i].to_i
      # current comp version number is more than
      # target version number: comp is newer.
      return false
    end
  end
  # Still here, meaning comp matches target to this point.
  # comp may be newer, but it is not older.
  return false
end

def components_list host_instance
  values = []
  host_instance['roles'].each do |role|
    # This addresses an error in older config files
    if role == 'mqserver'
      role = 'msgserver'
    end
    @role_map[role].each do |puppet_role|
      values << puppet_role['component']
    end
  end
  "[" + values.map{ |r| "'#{r}'" }.join(',') + "]"
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

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
if ARGV.length > 0
  if not ARGV[0].nil? and not ARGV[0] == 'nil'
    @target_node_hostname = ARGV[0]
  end
  if not ARGV[1].nil? and ARGV[1] == 'true'
    @puppet_template_only = true
  else
    @puppet_template_only = false
  end
end
@target_node_ssh_host = nil

# Default and baked-in config values for the Puppet deployment
@puppet_map = {
  'roles' => ['broker','activemq','datastore','named'],
  'jenkins_repo_base' => 'http://pkg.jenkins-ci.org/redhat',
}

# These values will be set in a Puppet config file
@env_input_map = {
  'subscription_type' => ['install_method'],
  'repos_base' => ['repos_base'],
  'os_repo' => ['os_repo'],
  'jboss_repo_base' => ['jboss_repo_base'],
  'os_optional_repo' => ['optional_repo'],
}

# Pull values that may have been passed on the command line into the launcher
@env_input_map.each_pair do |input,target_list|
  env_key = "OO_INSTALL_#{input.upcase}"
  if ENV.has_key?(env_key)
    target_list.each do |target|
      @puppet_map[target] = ENV[env_key]
    end
  end
end

@utility_install_order = ['named','datastore','activemq','broker','node']

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'broker' => [
    { 'component' => 'broker', 'env_hostname' => 'broker_hostname', 'env_ip_addr' => 'broker_ip_addr' },
    { 'component' => 'named', 'env_hostname' => 'named_hostname', 'env_ip_addr' => 'named_ip_addr' },
  ],
  'node' => [{ 'component' => 'node', 'env_hostname' => 'node_hostname', 'env_ip_addr' => 'node_ip_addr', 'env_ip_interface' => 'conf_node_external_eth_dev' }],
  'msgserver' => [{ 'component' => 'activemq', 'env_hostname' => 'activemq_hostname' }],
  'dbserver' => [{ 'component' => 'datastore', 'env_hostname' => 'datastore_hostname' }],
}

# Will map hosts to roles
@hosts = {}

config = YAML.load_file(@config_file)

# Set values from deployment configuration
@seen_roles = {}
if config.has_key?('Deployment') and config['Deployment'].has_key?('Hosts') and config['Deployment'].has_key?('DNS')
  config_hosts = config['Deployment']['Hosts']
  config_dns = config['Deployment']['DNS']

  config_hosts.each do |host_info|
    # Basic config file sanity check
    ['ssh_host','host','user','roles','ip_addr'].each do |attr|
      next if not host_info[attr].nil?
      puts "One of the hosts in the configuration is missing the '#{attr}' setting. Exiting."
      exit 1
    end

    # Map hosts by ssh alias
    @hosts[host_info['ssh_host']] = host_info

    # Set up the puppet-related ENV variables except node settings
    host_info['roles'].each do |role|
      # This addresses an error in older config files
      if role == 'mqserver'
        role = 'msgserver'
      end
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
        # Skip other node-oriented config for now.
        next
      end
      @role_map[role].each do |puppet_cfg|
        @puppet_map[puppet_cfg['env_hostname']] = host_info['host']
        if puppet_cfg.has_key?('env_ip_addr')
          if puppet_cfg['env_ip_addr'] == 'named_ip_addr' and host_info.has_key?('named_ip_addr')
            @puppet_map[puppet_cfg['env_ip_addr']] = host_info['named_ip_addr']
          else
            @puppet_map[puppet_cfg['env_ip_addr']] = host_info['ip_addr']
          end
        end
      end
    end

    if host_info['roles'].include?('broker') and not @puppet_template_only
      user = host_info['user']
      host = host_info['host']
      ssh_host = host_info['ssh_host']
      # In order for the default htpasswd account to work, we must first create an htpasswd file.
      htpasswd_cmds = {
        :mkdir_openshift => 'mkdir -p /etc/openshift',
        :touch_htpasswd => 'touch /etc/openshift/htpasswd',
      }
      if not user == 'root'
        htpasswd_cmds.each_pair do |action,command|
          htpasswd_cmds[action] = "sudo #{command}"
        end
      end
      full_command = "#{htpasswd_cmds[:mkdir_openshift]} && #{htpasswd_cmds[:touch_htpasswd]}"
      if not ssh_host == 'localhost'
        full_command = "#{@ssh_cmd} #{user}@#{ssh_host} \"#{full_command}\""
      end
      puts "Setting up htpasswd for default user account."
      system full_command
      if $?.exitstatus > 0
        puts "Could not create / verify '/etc/openshift/htpasswd' on target host. Exiting."
        exit 1
      end
    end
  end
  @puppet_map['domain'] = config_dns['app_domain']
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
  if not order_role == 'node' and not @target_node_ssh_host.nil?
    next
  end
  @hosts.each_pair do |ssh_host,host_info|
    host_info['roles'].each do |host_role|
      # This addresses an error in older config files
      if host_role == 'mqserver'
        host_role = 'msgserver'
      end
      @role_map[host_role].each do |origin_info|
        if origin_info['component'] == order_role
          if not @target_node_ssh_host.nil? and not @target_node_ssh_host == ssh_host
            next
          end
          if not host_order.include?(ssh_host)
            host_order << ssh_host
          end
        end
      end
    end
  end
end

# Summarize the plan
if @target_node_ssh_host.nil?
  puts "\nPreparing to install OpenShift Origin on the following hosts:\n"
else
  puts "\nPreparing to add this node to an OpenShift Origin system:\n"
end
host_order.each do |ssh_host|
  puts "  * #{ssh_host}: #{@hosts[ssh_host]['roles'].join(', ')}\n"
end

# Make it so
local_dns_key = nil
saw_deployment_error = false
@puppet_templates = []
@child_pids = []
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['user']
  host = @hosts[ssh_host]['host']

  puts "Deploying host '#{host}'"

  hostfile = "oo_install_configure_#{host}.pp"
  @puppet_map['roles'] = components_list(@hosts[ssh_host])

  # Set up the commands that we will be using.
  commands = {
    :typecheck => "export LC_CTYPE=en_US.utf8 && cat /etc/redhat-release",
    :keycheck => "ls /var/named/K#{@puppet_map['domain']}*.key",
    :keygen => "dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{@puppet_map['domain']}",
    :keyget => "cat /var/named/K#{@puppet_map['domain']}*.key",
    :enabledns => 'systemctl enable named.service',
    :enabledns_rhel => 'service named restart',
    :check => 'puppet module list --render-as yaml',
    :install => "puppet module install -v #{@puppet_module_ver} #{@puppet_module_name}",
    :upgrade => "puppet module upgrade --version=#{@puppet_module_ver} #{@puppet_module_name}",
    :yum_clean => 'yum clean all',
    :apply => "puppet apply --verbose /tmp/#{hostfile}",
    :clear => "rm /tmp/#{hostfile}",
  }
  puppet_commands = [:check,:install,:upgrade,:apply]
  # We have to prep and run :typecheck first.
  command_list = commands.keys
  if not command_list[0] == :typecheck
    command_list.delete_if{ |i| i == :typecheck }
    command_list.unshift(:typecheck)
  end
  # Modify the commands with sudo & ssh as necessary for this target host
  host_type = :fedora
  command_list.each do |action|
    if not ssh_host == 'localhost'
      if host_type == :other and puppet_commands.include?(action)
        commands[action] = "scl enable ruby193 \\\"#{commands[action]}\\\""
      end
      if not user == 'root'
        commands[action] = "sudo sh -c '#{commands[action]}'"
      end
      commands[action] = "#{@ssh_cmd} #{user}@#{ssh_host} -C \"#{commands[action]}\""
    else
      if host_type == :other and puppet_commands.include?(action)
        commands[action] = "scl enable ruby193 \"#{commands[action]}\""
      end
      commands[action] = "bash -l -c '#{commands[action]}'"
      if not user == 'root'
        commands[action] = "sudo #{commands[action]}"
      end
    end
    if action == :typecheck
      output = `#{commands[:typecheck]}`
      if not output.chomp.strip.downcase.start_with?('fedora')
        host_type = :other
      end
    end
  end

  # Figure out the DNS key before we write the puppet config file
  if @hosts[ssh_host]['roles'].include?('broker')
    puts "\nChecking for DNS key on #{ssh_host}..."
    output = `#{commands[:keycheck]}`
    chkstatus = $?.exitstatus
    if chkstatus > 0
      # No key; build one.
      puts "...none found; attempting to generate one.\n"
      output = `#{commands[:keygen]}`
      genstatus = $?.exitstatus
      if genstatus > 0
        puts "Could not generate a DNS key. Exiting."
        saw_deployment_error = true
        break
      end
      puts "Key generation successful."
    else
      puts "...found at /var/named/K#{@puppet_map['domain']}*.key\n"
    end
    # Copy the public key info to the config file.
    key_text = `#{commands[:keyget]}`
    getstatus = $?.exitstatus
    if getstatus > 0 or key_text.nil? or key_text == ''
      puts "Could not read DNS key data from /var/named/K#{@puppet_map['domain']}*.key. Exiting."
      saw_deployment_error = true
      break
    end
    # Format the public key correctly.
    key_vals = key_text.strip.split(' ')
    @puppet_map['bind_key'] = "#{key_vals[6]}#{key_vals[7]}"
    # Finally, make sure the named service is enabled.
    output = `#{commands[:enabledns]}`
    dnsstatus = $?.exitstatus
    if dnsstatus > 0
      # This may be RHEL (or at least, not systemd)
      puts "Command 'systemctl' didn't work; trying older style..."
      output = `#{commands[:enabledns_rhel]}`
      dnsstatus = $?.exitstatus
      if dnsstatus > 0
        puts "Could not enable named using command '#{commands[:enabledns]}'. Exiting."
        saw_deployment_error = true
        break
      else
        puts "Older style system command succeeded."
      end
    end
  end

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @puppet_map[@role_map['node'][0]['env_hostname']] = @hosts[ssh_host]['host']
    @puppet_map[@role_map['node'][0]['env_ip_addr']] = @hosts[ssh_host]['ip_addr']
    @puppet_map[@role_map['node'][0]['env_ip_interface']] = @hosts[ssh_host]['ip_interface']
  else
    @puppet_map.delete(@role_map['node'][0]['env_hostname'])
    @puppet_map.delete(@role_map['node'][0]['env_ip_addr'])
    @puppet_map.delete(@role_map['node'][0]['env_ip_interface'])
  end

  # Make a puppet config file for this host.
  filetext = "class { 'openshift_origin' :\n"
  @puppet_map.each_pair do |key,val|
    valtxt = key == 'roles' ? val : "'#{val}'"
    filetext << "  #{key} => #{valtxt},\n"
  end
  filetext << "}\n"

  # Write it out so we can copy it to the target
  hostfilepath = "/tmp/#{hostfile}"
  if @puppet_template_only and ENV.has_key?('HOME')
    hostfilepath = ENV['HOME'] + "/#{hostfile}"
  end
  if File.exists?(hostfilepath)
    File.unlink(hostfilepath)
  end
  fh = File.new(hostfilepath, 'w')
  fh.write(filetext)
  fh.close

  if @puppet_template_only
    @puppet_templates << hostfilepath
    puts "Created template #{hostfilepath}"
    next
  end

  # Handle the config file copying and delete the original.
  if not ssh_host == 'localhost'
    puts "Copying Puppet configuration script to target #{ssh_host}.\n"
    system "#{@scp_cmd} #{hostfilepath} #{user}@#{ssh_host}:#{hostfilepath}"
    if not $?.exitstatus == 0
      puts "Could not copy Puppet config to remote host. Exiting."
      saw_deployment_error = true
      break
    end
  end

  puts "\nRunning Puppet deployment"

  # Good to go; step through the puppet setup now.
  @child_pids << Process.fork do
    has_openshift_module = false
    openshift_module_needs_upgrade = false
    [:check,:install,:yum_clean,:apply,:clear].each do |action|
      if action == :clear and @keep_assets
        puts "Keeping #{hostfile}"
        next
      end
      if action == :install and has_openshift_module and not openshift_module_needs_upgrade
        puts "Skipping module installation."
        next
      end
      command = commands[action]
      if action == :install and openshift_module_needs_upgrade
        puts "OpenShift Puppet module will be upgraded to version #{@puppet_module_ver}."
        command = commands[:upgrade]
      end
      puts "\nRunning \"#{command}\"..."
      if ssh_host == 'localhost'
        clear_env
      end
      output = `#{command}`
      if ssh_host == 'localhost'
        restore_env
      end
      if $?.exitstatus == 0
        puts "Command completed."
      else
        # Note errors here but don't break; Puppet throws ignorable errors right now and we need to figure out how to deal with them
        saw_deployment_error = true
      end
      if action == :check
        # The gsub prevents ruby from trying to turn these back into Puppet::Module objects
        puppet_info = YAML::load(output.gsub(/\!ruby\/object:/, 'ruby_object: '))
        puppet_info.keys.each do |puppet_dir|
          puppet_info[puppet_dir].each do |puppet_module|
            next if not puppet_module['forge_name'] == @puppet_module_name
            has_openshift_module = true
            if is_older_puppet_module(puppet_module['version'])
              openshift_module_needs_upgrade = true
            end
          end
        end
      end
    end
    if saw_deployment_error
      puts "Warning: There were errors during the deployment on host '#{host}'."
    end
    # Delete the local copy of the puppet script if it is still present
    if not @keep_assets and File.exists?(hostfilepath)
      File.unlink(hostfilepath)
    end
    # Bail out of the fork
    exit
  end
end

# Wait for the parallel installs to finish
if not @puppet_template_only
  procs = Process.waitall
else
  if @puppet_templates.length > 0
    puts "\nThe following Puppet configuration files were generated\nfor use with the OpenShift Puppet module:\n* #{@puppet_templates.join("\n* ")}\n\n"
  else
    puts "\nErrors with the deployment setup prevented puppet configuration files from being generated. Please review the output above and try again."
  end
  exit
end

if saw_deployment_error
  puts "OpenShift Origin deployment completed with errors."
  exit 1
else
  puts "OpenShift Origin deployment completed."
  if host_order.length == 1
    puts "You should manually reboot #{@hosts[host_order[0]]['host']} to complete the process."
  else
    puts "You chould manually reboot these hosts in the indicated order to complete the process:"
    host_order.each_with_index do |ssh_host,idx|
      puts "#{idx + 1}. #{@hosts[ssh_host]['host']}"
    end
  end
end

exit
