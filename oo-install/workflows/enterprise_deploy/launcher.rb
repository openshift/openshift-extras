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

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
@target_node_index = ARGV[0].nil? ? nil : ARGV[0].split('::')[1].to_i
@target_node_host = nil

# Default and baked-in config values for the openshift.sh deployment
@env_map = { 'CONF_INSTALL_COMPONENTS' => 'all' }

# These values will be passed on the command line
@env_input_map = {
  'subscription_type' => ['CONF_INSTALL_METHOD'],
  'repos_base' => ['CONF_REPOS_BASE'],
  'os_repo' => ['CONF_RHEL_REPO'],
  'jboss_repo_base' => ['CONF_JBOSS_REPO_BASE'],
  'os_optional_repo' => ['CONF_RHEL_OPTIONAL_REPO'],
  'rh_username' => ['CONF_SM_REG_NAME','CONF_RHN_REG_NAME'],
  'rh_password' => ['CONF_SM_REG_PASS','CONF_RHN_REG_PASS'],
  'sm_reg_pool' => ['CONF_SM_REG_POOL'],
  'sm_reg_pool_rhel' => ['CONF_SM_REG_POOL_RHEL'],
  'rhn_reg_actkey' => ['CONF_RHN_REG_ACTKEY'],
}

# Pull values that may have been passed on the command line into the launcher
@env_input_map.each_pair do |input,target_list|
  env_key = "OO_INSTALL_#{input.upcase}"
  if ENV.has_key?(env_key)
    target_list.each do |target|
      @env_map[target] = ENV[env_key]
    end
  end
end

@utility_install_order = ['named','datastore','activemq','broker','node']

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'named' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'CONF_NAMED_HOSTNAME' },
  'broker' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'CONF_BROKER_HOSTNAME' },
  'node' => { 'deploy_list' => 'Nodes', 'role' => 'node', 'env_var' => 'CONF_NODE_HOSTNAME' },
  'activemq' => { 'deploy_list' => 'MsgServers', 'role' => 'mqserver', 'env_var' => 'CONF_ACTIVEMQ_HOSTNAME' },
  'datastore' => { 'deploy_list' => 'DBServers', 'role' => 'dbserver', 'env_var' => 'CONF_DATASTORE_HOSTNAME' },
}

# Will map hosts to roles
@hosts = {}

# This converts an ENV hash into a string of ENV settings
def env_setup
  @env_map.each_pair.map{ |k,v| "#{k}=#{v}" }.join(' ')
end

# This is a -very- simple way of making sure we don't inadvertently
# use a multicast IP addr or subnet mask. There's room for
# improvement here.
def find_good_ip_addrs list
  good_addrs = []
  list.each do |addr|
    next if addr == '127.0.0.1'
    triplets = addr.split('.')
    if not triplets[0].to_i == 255 and not triplets[-1].to_i == 255
      good_addrs << addr
    end
  end
  good_addrs
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

    for idx in 0..(@deployment_cfg[@role_map[role]['deploy_list']].length - 1)
      host_instance = @deployment_cfg[@role_map[role]['deploy_list']][idx]
      if role == 'node' and @target_node_index == idx
        @target_node_host = host_instance['ssh_host']
      end
      # The host map helps us sanity check and call openshift.sh jobs
      if not @hosts.has_key?(host_instance['ssh_host'])
        @hosts[host_instance['ssh_host']] = { 'roles' => [], 'username' => host_instance['user'], 'host' => host_instance['host'] }
      end
      @hosts[host_instance['ssh_host']]['roles'] << role

      # The env map is passed to each job, but nodes are handled individually
      if not role == 'node'
        @env_map[@role_map[role]['env_var']] = host_instance['host']
        if role == 'named' and @env_map['CONF_NAMED_IP_ADDR'].nil?
          if host_instance.has_key?('ip_addr')
            @env_map['CONF_NAMED_IP_ADDR'] = host_instance['ip_addr']
          else
            # Try to look up the IP address of the Broker host to set the named IP address
            # 1. Find the path to the 'ip' utility
            ip_path = nil
            if not host_instance['ssh_host'] == 'localhost'
              ip_path = %x[ "ssh #{host_instance['user']}@#{host_instance['ssh_host']} \"command -v ip\"" ].chomp
            else
              ip_path = which("ip")
            end
            if ip_path.nil?
              put "Could not find executable 'ip' on target system."
              exit 1
            end

            # 2. Get all of the non-loopback, non-netmask IPv4 addresses from the target system
            ip_lookup_command = "#{ip_path} addr show | grep inet | egrep -v inet6"
            if not host_instance['ssh_host'] == 'localhost'
              ip_lookup_command = "ssh #{host_instance['user']}@#{host_instance['ssh_host']} \"#{ip_lookup_command}\""
            end
            ip_text = %x[ #{ip_lookup_command} ].chomp
            ip_addrs = ip_text.split(/[\n\s\:\/]/).select{ |v| v.match(VALID_IP_ADDR_RE) }
            good_addrs = find_good_ip_addrs ip_addrs

            # 3. Pick the address or tell the user what to change
            if good_addrs.empty?
              puts "Could not determine a broker IP address for named. Trying socket lookup from this machine."
              socket_info = nil
              begin
                socket_info = Socket.getaddrinfo(host_instance['host'], 'ssh')
              rescue SocketError => e
                puts "Socket lookup of broker IP address failed. The installation cannot continue."
                exit
              end
              @env_map['CONF_NAMED_IP_ADDR'] = socket_info[0][SOCKET_IP_ADDR]
              puts "Found IP address #{@env_map['CONF_NAMED_IP_ADDR']}.\nThis may fail if the target host is in a different subnet than this local system.\nConsider re-running the installer and manually entering a valid IP address for this target system."
            elsif good_addrs.length == 1
              @env_map['CONF_NAMED_IP_ADDR'] = good_addrs[0]
            else
              puts "Found multiple possible IP addresses for target host #{host_instance['host']}:"
              good_addrs.each do |addr|
                puts "* #{addr}"
              end
              puts "The installer will attempt to continue with address #{good_addrs[0]}.\nConsider re-running the installer and manually entering a valid IP address for this target system."
              @env_map['CONF_NAMED_IP_ADDR'] = good_addrs[0]
            end
          end
        end
      end
    end
  end

  @env_map['CONF_DOMAIN'] = @deployment_cfg['DNS']['app_domain']
end

if @hosts.empty?
  puts "The config file at #{@config_file} does not contain OpenShift deployment information. Exiting."
  exit 1
end

if not @target_node_index.nil? and @target_node_host.nil?
  puts "The list of nodes in the config file at #{@config_file} is shorter than the index of the specified node host to be installed. Exiting."
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
  if not @target_node_host.nil? and @target_node_host == ssh_host and (roles.length > 1 or not roles[0] == 'node')
    puts "The specified node to be added also contains other OpenShift components.\nNodes can only be added as standalone components on their own systems. Exiting."
    exit 1
  end
end

# Set the installation order
host_order = []
@utility_install_order.each do |role|
  if not role == 'node' and not @target_node_host.nil?
    next
  end
  @hosts.select{ |key,hash| hash['roles'].include?(role) }.each do |matched_host|
    ssh_host = matched_host[0]
    if not @target_node_host.nil? and not @target_node_host == ssh_host
      next
    end
    if not host_order.include?(ssh_host)
      host_order << ssh_host
    end
  end
end

# Summarize the plan
if @target_node_host.nil?
  puts "Preparing to install OpenShift Enterprise on the following hosts:\n"
else
  puts "Preparing to add this node to an OpenShift Enterprise system:\n"
end
host_order.each do |ssh_host|
  puts "  * #{ssh_host}: #{@hosts[ssh_host]['roles'].join(', ')}\n"
end

# Run the jobs
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['username']
  @env_map['CONF_INSTALL_COMPONENTS'] = @hosts[ssh_host]['roles'].join(',')

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @env_map[@role_map['node']['env_var']] = @hosts[ssh_host]['host']
  else
    @env_map.delete(@role_map['node']['env_var'])
  end

  if not ssh_host == 'localhost'
    puts "Copying deployment script to target #{ssh_host}.\n"
    system "scp #{File.dirname(__FILE__)}/openshift.sh #{user}@#{ssh_host}:~/"
  end
  puts "Running deployment\n"
  if not ssh_host == 'localhost'
    system "ssh #{user}@#{ssh_host} 'chmod u+x ~/openshift.sh \&\& #{env_setup} ~/openshift.sh \&\& reboot'"
  else
    # Ruby 1.8-ism; we have to jam the env settings into our own ENV
    @env_map.each_pair do |env,val|
      ENV[env] = val
    end
    system "#{File.dirname(__FILE__)}/openshift.sh \&\& reboot"
  end

  puts "Installation on target #{ssh_host} completed.\n"
end

exit
