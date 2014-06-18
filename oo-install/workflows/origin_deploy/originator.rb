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

@scp_cmd = 'scp -q'
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
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

# Set some globals
set_context(:origin)
set_mode(true)

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

# This function quietly handles ENV for locally run commands
def execute_command host_instance, command
  clear_env if host_instance.localhost?
  output = host_instance.execute_on_host!(command)
  restore_env if host_instance.localhost?
  return output
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

def display_error_info host_instance, exec_info, message
 puts [
   "#{host_instance.host}: #{message}",
   "Output: #{exec_info[:stdout]}",
   "Error:  #{exec_info[:stderr]}",
   "Exiting installation on this host.",
 ].join("\n#{host_instance.host}: ")
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
    print "* Checking for #{dns_domain} DNS key... "
    key_filepath = "/var/named/K#{dns_domain}*.key"
    key_check    = host_instance.exec_on_host!("ls #{key_filepath}")
    if key_check[:exit_code] == 0
      puts 'found.'
    else
      # No key; build one.
      puts 'not found; attempting to generate.'
      key_gen = host_instance.exec_on_host!("dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{dns_domain}")
      if key_gen[:exit_code] == 0
        puts '* Key generation successful.'
      else
        display_error_info(host_instance, key_gen, 'Could not generate a DNS key.')
        return false
      end
    end

    # Copy the public key info to the config file.
    key_text = host_instance.exec_on_host!("cat #{key_filepath}")
    if key_text[:exit_code] != 0 or key_text[:stdout].nil? or key_text[:stdout] == ''
      display_error_info(host_instance, key_text, "Could not read DNS key data from #{key_filepath}.")
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
    puts '* BIND DNS enabled.'
  else
    display_error_info(host_instance, dns_restart, "Could not enable BIND DNS on #{host_instance.host}.")
    return false
  end
  return true
end

def close_all_ssh_sessions
  @deployment.hosts.each do |host_instance|
    next if host_instance.localhost?
    host_instance.close_ssh_session
  end
end

def utility_install_order
  @utility_install_order ||= [:nameserver,:dbserver,:msgserver,:broker,:node]
end

def restart_services host_instance
  services = []
  utility_install_order.each do |role|
    next if not host_instance.has_role?(role)
    case role
    when :nameserver
      services << 'named'
    when :dbserver
      services << 'mongod'
    when :msgserver
      services << 'activemq'
    when :broker
      services.concat(['openshift-broker','openshift-console'])
    when :node
      services.concat(['cgconfig','cgred','openshift-node-web-proxy','openshift-watchman'])
    else
      puts "Unrecognized role for restart: #{role}"
    end
  end

  if host_instance.is_broker? or host_instance.is_node?
    services << 'httpd'
  end

  if host_instance.is_msgserver? or host_instance.is_broker? or host_instance.is_node?
    services << 'ruby193-mcollective'
  end

  cmd = []
  cmd += services.map do |service|
    "/sbin/service #{service} stop;"
  end
  cmd << "rm -f /var/www/openshift/broker/httpd/run/httpd.pid;"
  cmd << "rm -f /var/www/openshift/console/httpd/run/httpd.pid;"
  cmd += services.map do |service|
    "/sbin/service #{service} start;"
  end
  cmd << "rm -rf /var/www/openshift/broker/tmp/cache/*;"
  cmd << "/etc/cron.minutely/openshift-facts;"
  cmd << "/sbin/service openshift-tc start || /sbin/service openshift-tc reload;"
  cmd << "/sbin/service network reload;"
  cmd << "/sbin/service network restart;"
  cmd << "/sbin/service messagebus restart;"
  cmd << "/sbin/service oddjobd restart;"

  restart_cmds = host_instance.exec_on_host!(cmd)
  if restart_cmds[:exit_code] == 0
    puts ""
  else
    #TODO
    display_error_info(host_instance, restart_cmds, '')
  end

  tc_status = host_instance.exec_on_host!('service openshift-tc status 2>/dev/null 1>/dev/null')
  if not tc_status[:exit_code] == 0
    host_instance.exec_on_host!('service openshift-tc reload')
  end
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
if host_installation_order.length == 0
  utility_install_order.each do |order_role|
    @deployment.get_hosts_by_role(order_role).each do |host_instance|
      next if host_installation_order.include?(host_instance)
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
if @deployment.dbservers.length == 1
  @puppet_global_config['mongodb_replicasets'] = false
  @puppet_global_config['datastore_hostname']  = @deployment.dbservers[0].host
end
if @deployment.msgservers.length == 1
  @puppet_global_config['msgserver_cluster']  = false
  @puppet_global_config['msgserver_hostname'] = @deployment.msgservers[0].host
end
if @deployment.nodes.length == 1
  @puppet_global_config['node_hostname']              = @deployment.nodes[0].host
  @puppet_global_config['node_ip_addr']               = @deployment.nodes[0].ip_addr
  @puppet_global_config['conf_node_external_eth_dev'] = @deployment.nodes[0].ip_interface
end

# These are ensured to be identical on all hosts.
[:mcollective_user,    :mcollective_password,
 :mongodb_broker_user, :mongodb_broker_password,
 :mongodb_admin_user,  :mongodb_admin_password,
 :openshift_user,      :openshift_password,
].each do |setting|
  @puppet_global_config[setting.to_s] = @deployment.hosts[0].send(setting)
end

# And finally, gear sizes.
@puppet_global_config['conf_valid_gear_sizes']          = @deployment.broker_global.valid_gear_sizes.join(',')
@puppet_global_config['conf_default_gear_capabilities'] = @deployment.broker_global.user_default_gear_sizes.join(',')
@puppet_global_config['conf_default_gear_size']         = @deployment.broker_global.default_gear_size

# Summarize the plan
if @puppet_template_only
  puts "\nPreparing puppet configuration files for the follwoing deployment:\n"
elsif @target_node_ssh_host.nil?
  puts "\nPreparing to install OpenShift Origin on the following hosts:\n"
else
  puts "\nPreparing to add this node to an OpenShift Origin system:\n"
end
host_installation_order.each do |host_instance|
  puts "  * #{host_instance.summarize}"
end

# Make the puppet templates
ordered_brokers    = @deployment.brokers.sort_by{ |h| h.host }
ordered_dbservers  = @deployment.dbservers.sort_by{ |h| h.host }
ordered_msgservers = @deployment.msgservers.sort_by{ |h| h.host }
@puppet_templates  = []
host_installation_order.each do |host_instance|
  puts "\nGenerating template for '#{host_instance.host}'"

  # If we are installing DNS, it will be on the first host out of the gate.
  if @deployment.dns.deploy_dns? and host_instance.is_nameserver? and not deploy_dns(host_instance)
    puts "The installer could not succesfully configure a DNS server on #{host_instance.host}. Exiting."
    exit 1
  end

  # Now we can start building the host-specific puppet config.
  hostfile                    = "oo_install_configure_#{host_instance.host}.pp"
  host_puppet_config          = @puppet_global_config.clone
  host_puppet_config['roles'] = components_list(host_instance)

  # Handle HA Brokers
  if @deployment.brokers.length > 1
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
    else
      # Non-broker hosts talk to the Brokers through the load balancer.
      host_puppet_config['broker_hostname'] = @deployment.load_balancers[0].broker_cluster_virtual_host
      host_puppet_config['broker_ip_addr']  = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
    end
  end

  # Handle HA DBServers
  if @deployment.dbservers.length > 1
    if host_instance.is_dbserver? or host_instance.is_broker?
      host_puppet_config['mongodb_replicasets']             = true
      host_puppet_config['mongodb_replicasets_members']     = '[' + ordered_dbservers.map{ |h| "'#{h.host}:#{h.ip_addr}'" }.join(',') + ']'
    end
    if host_instance.is_dbserver?
      host_puppet_config['datastore_hostname']              = host_instance.host
      host_puppet_config['mongodb_replica_primary']         = host_instance.is_db_replica_primary?
      host_puppet_config['mongodb_replica_primary_ip_addr'] = @deployment.db_replica_primaries[0].ip_addr
      host_puppet_config['mongodb_key']                     = @deployment.db_replica_primaries[0].mongodb_replica_key
      #dbserver_idx = 1
      #ordered_dbservers.each do |db_instance|
      #  host_puppet_config["datastore#{dbserver_idx}_ip_addr"] = db_instance.ip_addr
      #  dbserver_idx += 1
      #end
    end
  end

  # Handle HA MsgServers
  if @deployment.msgservers.length > 1
    if host_instance.is_msgserver? or host_instance.is_broker? or host_instance.is_node?
      host_puppet_config['msgserver_cluster']         = true
      host_puppet_config['msgserver_cluster_members'] = '[' + ordered_msgservers.map{ |h| "'#{h.host}'" }.join(',') + ']'
    end
    if host_instance.is_msgserver?
      host_puppet_config['msgserver_hostname'] = @deployment.msgservers[0].host
      host_puppet_config['msgserver_password'] = host_instance.msgserver_cluster_password
    end
  end

  # Make a puppet config file for this host.
  filetext = "class { 'openshift_origin' :\n"
  host_puppet_config.each_pair do |key,val|
    filetext << "  #{key} => #{val},\n"
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

  @puppet_templates << hostfilepath
  puts "* Created template #{hostfilepath}"

  next if @puppet_template_only

  # Copy the file over.
  if not host_instance.localhost?
    print "* Copying Puppet script to host... "
    `#{@scp_cmd} #{hostfilepath} #{host_instance.user}@#{host_instance.ssh_host}:#{hostfilepath} 2>&1`
    if not $?.exitstatus == 0
      puts "copy attempt failed.\nExiting.\n"
      close_all_ssh_sessions
      exit 1
    else
      if not @keep_assets and File.exists?(hostfilepath)
        puts 'success. Removing local copy.'
        File.unlink(hostfilepath)
      else
        puts 'success. Keeping local copy.'
      end
    end
  end
end

# Close any SSH sessions that got opened.
# For template-only jobs, we don't need them anymore, and
# for deployment jobs, we don't want to be forking with open sessions
close_all_ssh_sessions

# Summarize and head out for puppet template only
if @puppet_template_only
  if @puppet_templates.length > 1
    puts "\nAll puppet templates created:"
    @puppet_templates.each do |filename|
      puts "  * #{filename}"
    end
    puts wrap_long_string("To run them, copy them to their respective hosts and invoke them there with puppet: `puppet apply <filename>`.")
  else
    puts "\nPuppt template created at #{@puppet_templates[0]}"
    puts wrap_long_string("To run it, copy it to its host and invoke it with puppet: `puppet apply <filename>`.")
  end
  exit
end

############################################
# Stage 6: Run the Deployments in Parallel #
############################################

@child_pids = {}
host_installation_order.each do |host_instance|
  # Good to go; step through the puppet setup now.
  @child_pids[host_instance.host] = Process.fork do
    puts "#{host_instance.host}: Running Puppet deployment for host"

    if @keep_puppet
      puts "User specified that the openshift/openshift_origin module is already installed."
    else
      # Uninstall the existing puppet module (may or not not actually be present)
      del_module = execute_command(host_instance,"puppet module uninstall -f #{@puppet_module_name}")
      if del_module[:exit_code] == 0
        puts "#{host_instance.host}: Existing puppet module removed."
      else
        puts "#{host_instance.host}: Puppet module removal failed. This is expected if the module was not installed."
      end
      add_module = execute_command(host_instance,"puppet module install -v #{@puppet_module_ver} #{@puppet_module_name}")
      if not add_module[:exit_code] == 0
        display_error_info(host_instance, add_module, 'Puppet module installation failed')
        exit 1
      end
    end

    # Reset the yum repos
    yum_clean = execute_command(host_instance,'yum clean all')
    if not yum_clean[:exit_code] == 0
      display_error_info(host_instance, yum_clean, 'Failed to clean yum repo database')
      exit 1
    end

    # Make the magic
    run_apply = execute_command(host_instance,"puppet apply --verbose /tmp/#{hostfile} |& tee -a /tmp/openshift-deploy.log")
    if not run_apply[:exit_code] == 0
      display_error_info(host_instance, run_apply, 'Puppet deployment exited with errors')
      exit 1
    end

    if not @keep_assets
      clean_up = execute_command(host_instance,"rm /tmp/#{hostfile}")
      if not clean_up[:exit_code] == 0
        puts "#{host_instance.host}: Clean up of /tmp/#hostfile} failed; please remove this file manually."
      end
    else
      puts "#{host_instance.host}: Keeping /tmp/#{hostfile}"
    end

    if not host_instance.localhost?
      host_instance.close_ssh_session
    end

    # Bail out of the fork
    exit
  end
end

# Wait for the parallel installs to finish, inspect results.
procs  = Process.waitall
host_failures = []
host_installation_order.each do |host_instance|
  host_pid  = @child_pids[host_instance.host]
  host_proc = procs.select{ |process| process[0] == host_pid }[0]
  if not host_proc.nil?
    if not host_proc[1].exitstatus == 0
      host_failures << host_instance.host + ' (' + host_proc[1].exitstatus + ')'
    end
  else
    puts "Could not determine deployment status for host #{host_instance.host}"
  end
end

if host_failures.length == 0
  puts "\nHost deployments completed succesfully."
else
  if host_failures.length == host_installation_order.length
    puts "None of the host deployments succeeded:"
  else
    puts "The following host deployments failed:"
  end
  host_failures.each do |hostname|
    puts "  * #{hostname}"
  end
  puts "Please investigate these failures by starting with the /tmp/openshift-deploy.log file on each host.\nExiting installation with errors."
  exit 1
end

#########################################
# Stage 7: (Re)Start OpenShift Services #
#########################################

puts "\nRestarting services in dependency order."

host_installation_order.each do |host_instance|
  print "\nPerforming service restarts on #{host_instance.host}"
  if restart_services(host_instance)
    puts "...restarts successful."
  else
    puts "...restarts failed."
  end
end

###############################
# Stage 8: Post-Install Tasks #
###############################

puts "\nNow performing post-installation tasks.\n\nConfiguring districts."

# The post-install work can all be run from any broker.
broker = @deployment.brokers[0]
@deployment.districts.each do |district|
  district_cmd = "oo-admin-ctl-district -c create -n #{district.name} -p #{district.gear_size}"
  create_district = broker.exec_on_host!(district_cmd)
  if create_district[:exit_code] == 0
    puts "Successfully created district '#{district.name}'"
    district.node_hosts.each do |hostname|
      node_cmd = "oo-admin-ctl-district -c add-node -n #{district.name} -i #{hostname}"
      add_node = broker.exec_on_host!(node_cmd)
      if add_node[:exit_status] == 0
        puts "Added #{hostname} to district #{district.name}"
      else
        puts "Failed to add #{hostname} to district #{district.name}.\nYou will need to run the following manually from any Broker to add this node:\n\n\t#{node_cmd}"
      end
    end
  else
    puts "Failed to create district '#{district_name}'.\nYou will need to run the following manually on a Broker to create the district:\n\n\t#{district_cmd}\n\nThen you will need to run the add-node command for each associated node:\n\n\too-admin-ctl-district -c add-node -n #{district.name} -i <node_hostname>"
  end
end

puts "\nAttempting to register available cartridge types with Broker(s)."
carts_cmd = 'oo-admin-ctl-cartridge -c import-node --activate'
set_carts = broker.exec_on_host!(carts_cmd)
if not set_carts[:exit_code] == 0
  puts "Could not register cartridge types with Broker(s).\nLog into any Broker and attempt to register the carts with this command:\n\n\t#{carts_cmd}"
else
  puts "Cartridge registrations succeeded."
end

close_all_ssh_sessions

puts "Deployment successful. Exiting installer."

exit
