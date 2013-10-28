#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'

SOCKET_IP_ADDR = 3
VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')

# Check ENV for an alternate config file location.
if ENV.has_key?('CONF_CONFIG_FILE')
  @config_file = ENV['CONF_CONFIG_FILE']
else
  @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# This is a -very- simple way of making sure we don't inadvertently
# use a multicast IP addr or subnet mask. There's room for
# improvement here.
def find_good_ip_addrs list
  good_addrs = []
  list.each do |addr|
    next if addr == '127.0.0.1'
    triplets = addr.split('.')
    if not triplets[0].to_i == 255 and not triplets[2].to_i == 255
      good_addrs << addr
    end
  end
  good_addrs
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

@tmpdir = ENV['TMPDIR'] || '/tmp'
if @tmpdir.end_with?('/')
  @tmpdir = @tmpdir.chop
end

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
@target_node_hostname = ARGV[0].nil? ? nil : ARGV[0].split('::')[1].to_i
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
{ 'named' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'named_hostname' },
  'broker' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'broker_hostname' },
  'node' => { 'deploy_list' => 'Nodes', 'role' => 'node', 'env_var' => 'node_hostname' },
  'activemq' => { 'deploy_list' => 'MsgServers', 'role' => 'mqserver', 'env_var' => 'activemq_hostname' },
  'datastore' => { 'deploy_list' => 'DBServers', 'role' => 'dbserver', 'env_var' => 'datastore_hostname' },
}

# Will map hosts to roles
@hosts = {}

config = YAML.load_file(@config_file)

# Set values from deployment configuration
if config.has_key?('Deployment')
  @deployment_cfg = config['Deployment']

  # First, make a host map and a complete env map
  @role_map.keys.each do |role|
    # We only support multiple nodes; bail if we have multiple host instances for other roles.
    if not role == 'node' and @deployment_cfg[@role_map[role]['deploy_list']].length > 1
      puts "This workflow can only handle deployments containing a single #{role}. Exiting."
      exit 1
    end

    @deployment_cfg[@role_map[role]['deploy_list']].each do |host_instance|
      if role == 'node' and @target_node_hostname == host_instance['host']
        @target_node_ssh_host = host_instance['ssh_host']
      end
      # The host map helps us sanity check and call Puppet jobs
      if not @hosts.has_key?(host_instance['ssh_host'])
        @hosts[host_instance['ssh_host']] = { 'roles' => [], 'username' => host_instance['user'], 'host' => host_instance['host'] }
      end
      @hosts[host_instance['ssh_host']]['roles'] << role

      # The env map is passed to each job, but nodes are handled individually
      if not role == 'node'
        @puppet_map[@role_map[role]['env_var']] = host_instance['host']
        user = host_instance['user']
        host = host_instance['ssh_host']
        if role == 'named' and @puppet_map['named_ip_addr'].nil?
          if host_instance.has_key?('ip_addr')
            @puppet_map['named_ip_addr'] = host_instance['ip_addr']
          else
            puts "\nAttempting to discover IP address for host #{host_instance['host']}"
            # Try to look up the IP address of the Broker host to set the named IP address
            ip_path = nil
            if not host_instance['ssh_host'] == 'localhost'
              ip_path = %x[ ssh #{user}@#{host} 'command -v ip' ].chomp
            else
              ip_path = which("ip")
            end
            if ip_path.nil?
              puts "Could not determine path to 'ip' command"
              exit 1
            end

            ip_lookup_command = "#{ip_path} addr | grep inet | egrep -v inet6"
            if not host == 'localhost'
              ip_lookup_command = "ssh #{user}@#{host} \"#{ip_lookup_command}\""
            end
            ip_text = %x[ #{ip_lookup_command} ].chomp
            ip_addrs = ip_text.split(/[\s\:\/]/).select{ |v| v.match(VALID_IP_ADDR_RE) }
            good_addrs = find_good_ip_addrs ip_addrs
            if good_addrs.empty?
              puts "Could not determine a Broker IP address for named. Trying a lookup from the installer host."
              socket_info = nil
              begin
                socket_info = Socket.getaddrinfo(host_instance['host'], 'ssh')
              rescue SocketError => e
                puts "Socket lookup of broker IP address failed. The installation cannot continue."
                exit
              end
              @puppet_map['named_ip_addr'] = socket_info[0][SOCKET_IP_ADDR]
              puts "Using #{@puppet_map['named_ip_addr']} as Broker IP address."
            elsif good_addrs.length == 1
              @puppet_map['named_ip_addr'] = good_addrs[0]
            else
              puts "Found multiple possible IP addresses for target host #{host_instance['host']}:"
              good_addrs.each do |addr|
                puts "* #{addr}"
              end
              puts "The installer will attempt to continue with address #{good_addrs[0]}.\nConsider re-running the installer and manually entering a valid IP address for this target system."
              @puppet_map['named_ip_addr'] = good_addrs[0]
            end
          end
        end

        if role == 'broker'
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
          if not host == 'localhost'
            full_command = "ssh #{user}@#{host} '#{full_command}'"
          end
          puts "Setting up htpasswd for default user account."
          system full_command
          if $?.exitstatus > 0
            puts "Could not create / verify '/etc/openshift/htpasswd' on target host. Exiting."
            exit
          end
        end
        if role == 'datastore'
          # Make sure that /etc/hostname is an FQDN that matches
        end
      end
    end
  end
  @puppet_map['domain'] = @deployment_cfg['DNS']['app_domain']
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
@utility_install_order.each do |role|
  if not role == 'node' and not @target_node_ssh_host.nil?
    next
  end
  @hosts.select{ |key,hash| hash['roles'].include?(role) }.each do |matched_host|
    ssh_host = matched_host[0]
    if not @target_node_ssh_host.nil? and not @target_node_ssh_host == ssh_host
      next
    end
    if not host_order.include?(ssh_host)
      host_order << ssh_host
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
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['username']
  host = @hosts[ssh_host]['host']

  puts "Deploying host '#{host}'"

  hostfile = "oo_install_configure_#{host}.pp"
  @puppet_map['roles'] = "[" + @hosts[ssh_host]['roles'].map{ |r| "'#{r}'" }.join(',') + "]"

  # Set up the commands that we will be using.
  commands = {
    :keycheck => "ls /var/named/K#{@puppet_map['domain']}*.key",
    :keygen => "dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{@puppet_map['domain']}",
    :keyget => "cat /var/named/K#{@puppet_map['domain']}*.key",
    :enabledns => 'systemctl enable named.service',
    :enabledns_rhel => 'service named restart',
    :check => 'puppet module list',
    :install => 'puppet module install openshift/openshift_origin',
    :apply => "puppet apply --verbose ~/#{hostfile}",
    :clear => "rm ~/#{hostfile}",
    :reboot => 'reboot',
  }
  # Modify the commands with sudo & ssh as necessary for this target host
  commands.keys.each do |action|
    if not user == 'root' and not [:clear].include?(action)
      commands[action] = "sudo #{commands[action]}"
    end
    if not ssh_host == 'localhost'
      commands[action] = "ssh #{user}@#{ssh_host} '#{commands[action]}'"
    else
      commands[action] = "bash -l -c '#{commands[action]}'"
    end
  end

  # Figure out the DNS key before we write the puppet config file
  if @hosts[ssh_host]['roles'].include?('named')
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
      # This may be RHEL
      output = `#{commands[:enabledns_rhel]}`
      dnsstatus = $?.exitstatus
      if dnsstatus > 0
        puts "Could not enable named using command '#{commands[:enabledns]}'. Exiting."
        saw_deployment_error = true
        break
      end
    end
  end

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @puppet_map[@role_map['node']['env_var']] = @hosts[ssh_host]['host']
  else
    @puppet_map.delete(@role_map['node']['env_var'])
  end

  # Make a puppet config file for this host.
  filetext = "class { 'openshift_origin' :\n"
  @puppet_map.each_pair do |key,val|
    valtxt = key == 'roles' ? val : "'#{val}'"
    filetext << "  #{key} => #{valtxt},\n"
  end
  filetext << "}\n"

  # Write it out so we can copy it to the target
  hostfilepath = "#{@tmpdir}/#{hostfile}"
  if File.exists?(hostfilepath)
    File.unlink(hostfilepath)
  end
  fh = File.new(hostfilepath, 'w')
  fh.write(filetext)
  fh.close

  # Handle the config file copying and delete the original.
  if not ssh_host == 'localhost'
    puts "Copying Puppet configuration script to target #{ssh_host}.\n"
    system "scp #{hostfilepath} #{user}@#{ssh_host}:~/"
    if not $?.exitstatus == 0
      puts "Could not copy Puppet config to remote host. Exiting."
      saw_deployment_error = true
      break
    else
      # Copy succeeded, remove original
      File.unlink(hostfilepath)
    end
  else
    # localhost; relocate .pp file
    puts "Moving Puppet configuration to #{ENV['HOME']}"
    system "mv #{hostfilepath} #{ENV['HOME']}"
  end

  puts "\nRunning Puppet deployment\n\n"

  # Good to go; step through the puppet setup now.
  has_openshift_module = false
  [:check,:install,:apply,:clear].each do |action|
    if action == :install and has_openshift_module
      puts "Skipping module installation."
      next
    end
    command = commands[action]
    if ssh_host == 'localhost'
      clear_env
    end
    output = `#{command}`
    if ssh_host == 'localhost'
      restore_env
    end
    if $?.exitstatus == 0
      puts "Command \"#{command}\" on target #{ssh_host} completed.\n"
    else
      saw_deployment_error = true
      break
    end
    if action == :check and output.match('openshift')
      has_openshift_module = true
    end
  end
  if saw_deployment_error
    puts "Exiting due to errors on host '#{host}'"
    break
  end
end
if saw_deployment_error
  exit 1
else
  puts "OpenShift Origin deployment completed."
end

exit
