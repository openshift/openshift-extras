#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'
require 'installer'
require 'installer/helpers'
require 'installer/config'

include Installer::Helpers

######################################
# Stage 1: Handle ENV and ARGV input #
######################################

@puppet_module_name = 'openshift/openshift_origin'
@puppet_module_ver = '4.0.0'

# Check ENV for an alternate config file location.
if ENV.has_key?('OO_INSTALL_CONFIG_FILE')
  @config_file = ENV['OO_INSTALL_CONFIG_FILE']
else
  @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# Check to see if we need to preserve generated files.
@keep_assets = ENV.has_key?('OO_INSTALL_KEEP_ASSETS') and ENV['OO_INSTALL_KEEP_ASSETS'] == 'true'

# Check to see if we are installing the puppet module on the target hosts
@keep_puppet = ENV.has_key?('OO_INSTALL_KEEP_PUPPET') and ENV['OO_INSTALL_KEEP_PUPPET'] == 'true'

@ssh_cmd = 'ssh -t -q'
@scp_cmd = 'scp -q'
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
  @ssh_cmd = 'ssh -t -v'
  @scp_cmd = 'scp -v'
  set_debug(true)
else
  set_debug(false)
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

#############################################
# Stage 2: Load and check the configuration #
#############################################

# Because this is the Originator!
set_context(:origin)

openshift_config = Installer::Config.new(@config_file)
if not openshift_config.is_valid?
  puts "Could not process config file at '#{@config_file}'. Exiting."
  exit 1
end

@deployment = openshift_config.get_deployment
errors = @deployment.is_valid?(:full)
if errors.length > 0
  puts "The OpenShift deployment configuration has the following errors:"
  errors.each do |error|
    puts "  * #{error.message}"
  end
  puts "Rerun the installer to correct these errors."
  exit 1
end

subscription = openshift_config.get_subscription
errors = subscription.is_valid?(:full)
if errors.length > 0
  puts "The OpenShift subscription configuration has the following errors:"
  errors.each do |error|
    puts "  * #{error}"
  end
  puts "Rerun the installer to correct these errors."
  exit 1
end

# Start cooking up the common settings for all target hosts
@puppet_global_config = {}

###############################################
# Stage 3: Define some locally useful methods #
###############################################

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
  host_instance.roles.each do |role|
    # This addresses an error in older config files
    role_value = role == :dbserver ? 'datastore' : role.to_s
    values << role_value
  end
  if host_instance.is_load_balancer?
    values << 'load_balancer'
  end
  "[" + values.join(',') + "]"
end

# Sets up BIND on the nameserver host.
# Also sets the nsupdate key values for all hosts.
def deploy_dns host_instance
  # Before we deploy puppet, we need to (possibly generate) and read out the nsupdate key(s)
  domain_list = [@deployment.dns.app_domain]
  if @deployment.dns.register_components?
    domain_list << @deployment.dns.component_domain
  end
  domain_list.each do |dns_domain|
    puts "\nChecking for #{dns_domain} DNS key on #{host_instance.host}..."
    key_filepath = "/var/named/K#{dns_domain}*.key"
    key_check    = host_instance.exec_on_host!("ls #{key_filepath}")
    if key_check[:exit_code] == 0
      puts "...found at #{key_filepath}\n"
    else
      # No key; build one.
      puts "...none found; attempting to generate one.\n"
      key_gen = host_instance.exec_on_host!("dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{dns_domain}")
      if key_gen[:exit_status] == 0
        puts "Key generation successful."
      else
        puts "Could not generate a DNS key. Exiting."
        return false
      end
    end

    # Copy the public key info to the config file.
    key_text = host_instance.exec_on_host!("cat #{key_filepath}")
    if key_text[:exit_code] != 0 or key_text[:stdout].nil? or key_text[:stdout] == ''
      puts "Could not read DNS key data from #{key_filepath}. Exiting."
      return false
    end

    # Format the public key correctly.
    key_vals     = key_text[:stdout].strip.split(' ')
    nsupdate_key = "#{key_vals[6]}#{key_vals[7]}"
    if dns_domain == @deployment.dns.app_domain
      @puppet_global_config['bind_key'] = nsupdate_key
    else
      @puppet_global_config['dns_infrastructure_key'] = nsupdate_key
    end
  end

  # Make sure BIND is enabled.
  dns_restart = host_instance.exec_on_host!('service named restart')
  if dns_restart[:exit_code] == 0
    puts 'BIND DNS enabled.'
  else
    puts "Could not enable BIND DNS on #{host_instance.host}. Exiting."
    return false
  end
  return true
end

############################################
# Stage 4: Workflow-specific configuration #
############################################

# See if the Node to add exists in the config
host_installation_order = []
if not @target_node_hostname.nil?
  @deployment.get_hosts_by_role(:node).select{ |h| h.roles.count == 1 and h.host == @target_node_hostname }.each do |host_instance|
    @target_node_ssh_host = host_instance.ssh_host
    host_installation_order << host_instance
    break
  end
  if @target_node_ssh_host.nil?
    puts "The list of nodes in the config file at #{@config_file} does not contain an entry for #{@target_node_hostname}. Exiting."
    exit 1
  end
end

###############################################
# Stage 5: Map config to puppet for each host #
###############################################

# These values will be set in all Puppet config files
@env_input_map = {
  'subscription_type' => 'install_method',
  'repos_base'        => 'repos_base',
  'os_repo'           => 'os_repo',
  'jboss_repo_base'   => 'jboss_repo_base',
  'jenkins_repo_base' => 'jenkins_repo_base',
  'os_optional_repo'  => 'optional_repo',
}

# Pull values that may have been passed on the command line into the launcher
# (Typically, usernames & passwords associated with subscription methods)
@env_input_map.each_pair do |env_var,puppet_var|
  env_key = "OO_INSTALL_#{env_var.upcase}"
  if ENV.has_key?(env_key)
    @puppet_global_config[puppet_var] = ENV[env_key]
  end
end

# Set the installation order (if the Add a Node workflow didn't already set it)
@utility_install_order = [:nameserver,:dbserver,:msgserver,:broker,:node]
if host_installation_order.length == 0
  @utility_install_order.each do |order_role|
    @deployment.get_hosts_by_role(order_role).each do |host_instance|
      next if host_order.include?(host_instance.host)
      host_installation_order << host_instance
      # We're done as soon as all of the hosts are ordered
      break if host_installation_order.length == @deployment.hosts.length
    end
    # We're done as soon as all of the hosts are ordered
    break if host_installation_order.length == @deployment.hosts.length
  end
end

# Set up the global puppet settings
@puppet_global_config['domain'] = @deployment.dns.app_domain
if @deployment.dns.deploy_dns?
  @puppet_global_config['nameserver_hostname'] = @deployment.nameservers[0].host
  @puppet_global_config['nameserver_ip_addr']  = @deployment.nameservers[0].ip_addr
  if @deployment.dns.register_components?
    if @deployment.dns.component_domain == @deployment.dns.app_domain
      @puppet_global_config['register_host_with_nameserver'] = true
    else
      @puppet_global_config['dns_infrastructure_zone']  = @deployment.dns.component_domain
      @puppet_global_config['dns_infrastructure_names'] = '[' + @deployment.hosts.map{ |h| "{ hostname => '#{h.host}', ipaddr => '#{h.ip_addr}' }" }.join(',') + ']'
    end
  end
else
  @puppet_global_config['nameserver_hostname'] = @deployment.dns.dns_host_name
  @puppet_global_config['nameserver_ip_addr']  = @deployment.dns.dns_host_ip
  @puppet_global_config['bind_key']            = @deployment.dns.dnssec_key
end
if @deployment.brokers.length == 1
  @puppet_global_config['broker_hostname'] = @deployment.brokers[0].host
  @puppet_global_config['broker_ip_addr']  = @deployment.brokers[0].ip_addr
else
  @puppet_global_config['broker_hostname'] = @deployment.load_balancers[0].broker_cluster_virtual_host
  @puppet_global_config['broker_ip_addr']  = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
end
if @deployment.dbservers.length = 1
  @puppet_global_config['dbserver_hostname'] = @deployment.dbservers[0].host
  @puppet_global_config['dbserver_ip_addr']  = @deployment.dbservers[0].ip_addr
end
if @deployment.msgservers.length = 1
  @puppet_global_config['msgserver_hostname'] = @deployment.msgservers[0].host
  @puppet_global_config['msgserver_ip_addr']  = @deployment.msgservers[0].ip_addr
end
if @deployment.msgservers.length = 1
  @puppet_global_config['msgserver_hostname'] = @deployment.msgservers[0].host
  @puppet_global_config['msgserver_ip_addr']  = @deployment.msgservers[0].ip_addr
end
if @deployment.nodes.length = 1
  @puppet_global_config['node_hostname']              = @deployment.node[0].host
  @puppet_global_config['node_ip_addr']               = @deployment.node[0].ip_addr
  @puppet_global_config['conf_node_external_eth_dev'] = @deployment.node[0].ip_interface
end

# Summarize the plan
if @target_node_ssh_host.nil?
  puts "\nPreparing to install OpenShift Origin on the following hosts:\n"
else
  puts "\nPreparing to add this node to an OpenShift Origin system:\n"
end
host_installation_order.each do |host_instance|
  puts "  * #{host_instance.summarize}"
end

# Make it so
@nsupdate_keys       = {}
saw_deployment_error = false
@child_pids = []
host_installation_order.each do |host_instance|
  puts "Deploying host '#{host_instance.host}'"

  # If we are installing DNS, it will be on the first host out of the gate.
  if @deployment.dns.deploy_dns? and host_instance.is_nameserver? and not deploy_dns(host_instance)
    saw_deployment_error = true
    break
  end

  break if saw_deployment_error

  # Now we can start building the host-specific puppet config.
  hostfile = "oo_install_configure_#{host_instance.host}.pp"
  host_puppet_config = @puppet_global_config.clone
  host_puppet_config['roles'] = components_list(host_instance)

  # Handle HA Brokers
  if @deployment.brokers.length > 1
    ordered_brokers = @deployment.brokers.sort_by{ |h| h.host }
    # DNS is used to configure the load balancer
    if host_instance.is_nameserver?
      host_puppet_config['broker_virtual_hostname']   = @deployment.load_balancers[0].broker_cluster_virtual_host
      host_puppet_config['broker_virtual_ip_address'] = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
    end
    # Brokers
    if host_instance.is_broker?
      host_puppet_config['broker_hostname']             = host_instance.host
      host_puppet_config['broker_ip_addr']              = host_instance.ip_addr
      host_puppet_config['broker_cluster_members']      = '[' + ordered_brokers.map{ |h| h.host }.join(',') + ']'
      host_puppet_config['broker_cluster_ip_addresses'] = '[' + ordered_brokers.map{ |h| h.ip_addr }.join(',') + ']'
      host_puppet_config['broker_virtual_ip_address']   = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
      if host_instance.is_load_balancer?
        host_puppet_config['load_balancer_master']    = true
        host_puppet_config['broker_virtual_hostname'] = @deployment.load_balancers[0].broker_cluster_virtual_host
      else
        host_puppet_config['load_balancer_master'] = false
      end
    end
  end
  # Handle HA DBServers
  if @deployment.dbservers.length > 1
    if host_instance.is_dbserver?
      #TODO
    end
  end
  # Handle HA MsgServers
  if @deployment.msgservers.length > 1
  end

  logfile = "/tmp/openshift-deploy.log"

  # Set up the commands that we will be using.
  commands = {
    :uninstall => "puppet module uninstall -f #{@puppet_module_name}",
    :install => "puppet module install -v #{@puppet_module_ver} #{@puppet_module_name}",
    :yum_clean => 'yum clean all',
    :apply => "puppet apply --verbose /tmp/#{hostfile} |& tee -a #{logfile}",
    :clear => "rm /tmp/#{hostfile}",
  }

  # Cleanup host specific puppet parameters from any previous runs
  @hosts[ssh_host]['roles'].each do |role|
    @role_map[role].each do |origin_role|
      origin_role.values.each do |puppet_param|
        @puppet_map.delete(puppet_param)
      end
    end
  end

  # Set host specific puppet parameters
  @hosts[ssh_host]['roles'].each do |role|
    @role_map[role].each do |origin_role|
      origin_role.each do |config_var, puppet_param|
        case config_var
        when 'env_hostname'
          @puppet_map[puppet_param] = @hosts[ssh_host]['host']
        when 'env_ip_addr'
          if puppet_param == 'named_ip_addr' and @hosts[ssh_host].has_key?('named_ip_addr')
            @puppet_map[puppet_param] = @hosts[ssh_host]['named_ip_addr']
          else
            @puppet_map[puppet_param] = @hosts[ssh_host]['ip_addr']
          end
        else
          @puppet_map[puppet_param] = @hosts[ssh_host][config_var] unless @hosts[ssh_host][config_var].nil?
        end
      end
    end

    # Set needed env variables that are not explicitly configured on the host
    @hosts.values.each do |host_info|
      # Both the broker and node need to set the activemq hostname, but it is not stored in the config
      if ['broker','node'].include?(role) and @hosts[ssh_host]['roles'].include?('msgserver')
        @puppet_map['activemq_hostname'] = @hosts[ssh_host]['host']
      end

      # The broker needs to set the datastore hostname, but it is not stored in the config
      if role == 'broker' and @hosts[ssh_host]['roles'].include?('dbserver')
        @puppet_map['datastore_hostname'] = @hosts[ssh_host]['host']
      end
      # All hosts need to set the named ip address, but only the broker stores it in the config
      if role != 'broker' and @hosts[ssh_host]['roles'].include?('broker')
        @puppet_map['named_ip_addr'] = @hosts[ssh_host]['named_ip_addr']
      end

      if role == 'node' and @hosts[ssh_host]['roles'].include?('broker')
        @puppet_map['broker_hostname'] = @hosts[ssh_host]['host']
      end
    end
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
    scp_output = `#{@scp_cmd} #{hostfilepath} #{user}@#{ssh_host}:#{hostfilepath} 2>&1`
    if not $?.exitstatus == 0
      puts "Could not copy Puppet config to remote host. Exiting.\n"
      saw_deployment_error = true
      break
    end
  end

  puts "\nRunning Puppet deployment\n"

  # Good to go; step through the puppet setup now.
  @child_pids << Process.fork do
    [:uninstall,:install,:yum_clean,:apply,:clear].each do |action|
      if @keep_puppet and [:uninstall, :install].include?(action)
        if action == :uninstall
          puts "User specified that the openshift/openshift_origin module is already installed.\n"
        end
        next
      end
      if action == :clear and @keep_assets
        puts "Keeping #{hostfile}\n"
        next
      end
      command = commands[action]
      puts "\nRunning: #{command}\n"
      if ssh_host == 'localhost'
        clear_env
      end
      output = `#{command} 2>&1`
      if ssh_host == 'localhost'
        restore_env
      end
      if $?.exitstatus == 0
        puts "Command completed.\n"
      else
        if action == :uninstall
          puts "Uninstall command failed; this is expected if the puppet module wasn't previously installed.\n"
        else
          # Note errors here but don't break; Puppet throws ignorable errors right now and we need to figure out how to deal with them
          saw_deployment_error = true
        end
      end
      if action == :check
        # The gsub prevents ruby from trying to turn these back into Puppet::Module objects
        begin
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
        rescue Psych::SyntaxError => e
          has_openshift_module = false
          openshift_module_needs_upgrade = false
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
