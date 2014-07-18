#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'
require 'installer'
require 'installer/helpers'
require 'installer/config'
require 'installer/deployment'
require 'installer/host_instance'

include Installer::Helpers

# Globals
set_context(:ose)
set_mode(true)


# Set the scp command arguments and debug settings.
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
  @scp_cmd = 'scp -v'
  set_debug(true)
else
  @scp_cmd = 'scp -q'
  set_debug(false)
end


# Common settings for all target hosts
@env_map          = {}
@mongodb_port     = 27017

#####################################
# Stage 1: Install Order + Messages #
#####################################

# steps/states/actions are arrays with corresponding indices
INSTALL_STEPS = %w[ . prepare install configure define_hosts post_deploy run_diagnostics ]
INSTALL_STATES = %w[ new prepared installed completed completed completed completed validated broken ]
INSTALL_ACTIONS = %w[ .
                      init_message,validate_preflight,configure_repos
                      install_rpms
                      configure_host,configure_openshift,restart_services
                      register_named_entries
                      post_deploy
                      run_diagnostics
                    ]
STEP_SUCCESS_MSG = <<"MSGS".split "\n"
.
OpenShift: Completed configuring repos.
OpenShift: Completed installing RPMs.
OpenShift: Completed configuring OpenShift.
OpenShift: Completed updating host DNS entries.
OpenShift: Completed post deployment steps.
OpenShift: Completed running oo-diagnostics.
MSGS

######################################
# Stage 2: Handle ENV and ARGV input #
######################################
# Check to see if we need to preserve generated files.
@keep_assets = ENV.has_key?('OO_INSTALL_KEEP_ASSETS') and ENV['OO_INSTALL_KEEP_ASSETS'] == 'true'

# Set the path to the configuration file.
# Check if there is an existing configuration file.
if ENV.has_key?('OO_INSTALL_CONFIG_FILE')
    @config_file = ENV['OO_INSTALL_CONFIG_FILE']
else
    @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
if ARGV.length > 0
    if not ARGV[0].nil? and not ARGV[0] == 'nil'
        @target_node_hostname = ARGV[0]
    end
end

#########################################
# Stage 3:  Load + Verify Configuration #
#########################################

openshift_config = Installer::Config.new(@config_file)
@deployment = openshift_config.get_deployment
@subscription = openshift_config.get_subscription

if not openshift_config.is_valid?
    puts "Could not process config file at '#{@config_file}'. Exiting."
    exit 1
end

# Get Subscription Configuration
sub_errors = @subscription.is_valid?(:full)
if sub_errors.length > 0
    puts "The OpenShift subscription configuration has the following errors:"
    sub_errors.each do |error|
        puts "  * #{error}"
    end
    puts "Rerun the installer to correct these errors."
    exit 1
end

#####################################################
# Stage 4: Load Some Useful Methods for this Script #
#####################################################


def save_and_exit(code = 0)
  File.open(@config_file, 'a') {|file| file.write @config.to_yaml}
  exit code
end

## Updated version of "components_list"
def components_list host_instance
    values = []
    host_instance.roles.each do |role|
        # this addresses an error in older config files
        role_value = role == :dbserver  ? 'datastore' : role.to_s
        values << role_value
    end
    if host_instance.is_load_balancer?
        values << 'load_balancer'
    end
    values.map{ |r| "#{r}"}.join(',')
end

def display_error_info host_instance, exec_info, message
    puts [
    "#{host_instance.host}: #{message}",
    "Output: #{exec_info[:stdout]}",
    "Error: #{exec_info[:stderr]}",
    "Exiting installation on this host.",
    ].join("\n#{host_instance.host}: ")
end

# Sets up BIND on nameserver host.
# Also sets the nsupdate key values for all hosts.
def deploy_dns host_instance
    domain_list = [@deployment.dns.app_domain]
    if @deployment.dns.register_components?
        domain_list << @deployment.dns.component_domain
    end
    domain_list.each do |dns_domain|
        print "* Checking for #{dns_domain} DNS key..."
        key_filepath = "/var/named/K#{dns_domain}.*.key"
        key_check = host_instance.exec_on_host!("ls #{key_filepath}")
        if key_check[:exit_code] == 0
            puts "found."
        else
            # No key; build one.
            puts "not found; attempting to generate."
            key_gen = host_instance.exec_on_host!("dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{dns_domain}")
            if key_gen[:exit_code] == 0
                puts "* Key generation successful."
            else
                display_error_info(host_instance, key_gen, "Could not generate a DNS key.")
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
    # Updates questions in assistant to make more clear.
    @env_map['CONF_BIND_KEY'] = nsupdate_key

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
end


def close_all_ssh_sessions
    @deployment.hosts.each do |host_instance|
        next if host_instance.localhost?
        host_instance.close_ssh_session
    end
end

def utility_install_order
    @utility_install_order ||= [:named, :dbserver, :msgserver, :broker, :node]
end

def manage_service service, hosts, action=:restart
    hosts.each do |host_instance|
        result = host_instance.exec_on_host!("/sbin/service #{service.to_s} #{action.to_s}")
        if result[:exit_code] == 0
            puts "#{host_instance.host}: service #{service.to_s} #{action.to_s} succeeded."
        else
            puts "#{host_instance.host}: service #{service.to_s} #{action.to_s} failed: #{result[:stderr]}"
        end
    end
end

def configure_mongodb_replica_set
    puts "\nRegistering MongoDB replica set"
    db_primary = @deployment.db_replica_primaries[0]

    init_cmd = "mongo admin -u #{db_primary.mongodb_admin_user} -p #{db_primary.mongodb_admin_password} --quiet --eval \"printjson(rs.initiate())\""
    init_result = execute_command db_primary, init_cmd
    if init_result[:exit_code] == 0
        puts "MongoDB replicaset initialized."
        sleep 10
    else
        display_error_info db_primary, init_result, "The MongoDB replicaset could not be initialized"
        exit 1
    end

    @deployment.dbservers.each do |host_instance|
        check_cmd = "mongpo admin - u #{host_instance.mongodb_admin_user} -p #{host_instance.mongodb_admin_password} -quiet --eval \"printjson(rs.status())\" | grep '\"name\" : \"#{host_instance.ip_addr}:#{@mongodb_port}\"'"
        check_result = execute_command db_primary, check_cmd
        if check_result[:exit_code] == 0
            puts "MongoDB replica member #{host_instance.host} already registered."
        else
            add_cmd = "mongo admin -u #{host_instance.mongodb_admin_uesr} -p #{host_instance.mongodb_admin_password} -quiet --eval \"printjson(rs.add(\'#{host_instance.ip_addr}:#{@mongodb_port}\'))\""
            add_result = db_primary.exec_on_host!(add_cmd)
            if add_result[:exit_code] == 0
                puts "MongoDB replica member #{host_instance.host} registered."
            else
                display_error_info host_instance, add_result, "this host could not be registered as a MongodB replica member"
                exit 1
            end
        end
    end
end
  # The hostfile contains the environment variables for each host in a deployment.
  # After setting the environment variables, it calls openshift.sh to complete
  # installation.

  @openshift_sh_path = "./"
  @openshift_sh = "openshift.sh"
  def base_config component, mode
    # Header
    if component == "header"
      open(@hostfile, mode) do |output|
        output << "#!/bin/bash\n"
        output << "# Host configuration for OpenShift.\n"
        output << "set -e\n"
      end
    end
    # Footer
    if component == "footer"
      open(@hostfile, mode) do |output|
        output << "#{@openshift_sh_path}#{@openshift_sh}\n"
        output << "exit\n"
      end
    end
  end

  def set_config_env configmap
    configmap.each_pair do |hash, key|
      open(@hostfile, "a") do |output|
        output << "export #{hash}=\"#{key}\"\n"
      end
    end
  end

  def clear_config
    # Write a blank file.
    open(@hostfile, "w") do |out|; end
  end

  def build_config(host_instance, host_config)
    @hostfile = "host_config_#{host_instance.host}.sh"
    # Clear the file.
    clear_config
    # Start writing in the header of the host deployment script.
    base_config "header", "a"
    # Add the necessary environment variables.
    set_config_env host_config
    # Add the footer to the end of the configuration file.
    base_config "footer", "a"
  end



############################################
# Stage 4: Workflow-specific configuration #
############################################
host_installation_order = []

if not @target_node_hostname.nil?
  @deployment.nodes.select{ |h| h.roles.count == 1 and h.host = @target_node_hostname }.each do |host_instance|
    @target_node = host_instance
    host_installation_order << host_instance
    break
  end
  if @target_node.nil?
    puts "The list of nodes in the config file at #{@config_file} does not contain an entry for #{@target_node_hostname}. Exiting."
    exit 1
  end
end

@subscription_map = {
    'subscription_type' => 'CONF_INSTALL_METHOD',
    'repos_base'        => 'CONF_REPOS_BASE',
    'os_repo'           => 'CONF_RHEL_REPO',
    'jboss_repo_base'   => 'CONF_JBOSS_REPO_BASE',
    'os_optional_repo'  => 'CONF_RHEL_OPTIONAL_BASE',
    'scl_repo'          => 'CONF_RHSCL_REPO_BASE',
    'rh_username'       => 'CONF_RHN_USER',
    'rh_password'       => 'CONF_RHN_PASS',
    'sm_reg_pool'       => 'CONF_SM_REG_POOL',
    'rhn_reg_actkey'    => 'CONF_RHN_REG_ACTKEY',
}
@subscription_map.each do |env_var, sh_var|
  env_key = "OO_INSTALL_#{env_var.upcase}"
  if ENV.has_key?(env_key)
    sh_var.each { |target| @env_map[target] = ENV[env_key]}
  end
end
# Set the installation order (if the Add a Node workflow didn't already set it)
if host_installation_order.length == 0
    utility_install_order.each do |order_role|
        @deployment.get_hosts_by_role(order_role).each do |host_instance|
            next if host_installation_order.include?(host_instance)
            # We're done as soon as all of the hosts are ordered.
            host_installation_order << host_instance
            break if host_installation_order.length == @deployment.hosts.length
        end
        # We're done as soon as all of the hosts are ordered.
        break if host_installation_order.length == @deployment.hosts.length
    end
end


# Set up global settings (same as @puppet_global_config)
@env_map['CONF_DOMAIN'] = @deployment.dns.app_domain
if @deployment.dns.deploy_dns?
  @env_map['CONF_NAMED_HOSTNAME'] = @deployment.nameservers[0].host
  @env_map['CONF_NAMED_IP_ADDR'] = @deployment.nameservers[0].ip_addr
  if @deployment.dns.register_components?
    if @deployment.dns.component_domain == @deployment.dns.app_domain
     # only set if we're creating an app domain.
     # runs nsupdate to add record to ns
     # if CONF_HOST_DOMAIN is set, create that zone.
     # CONF_NAMED_ENTRIES (see line 412 in old)
    else
      infra_host_list = @deployment.hosts.map { |h| "{ hostname => '#{h.host}', ipaddr => '#{h.ip_addr}' }" }
      if @deployment.brokers.length > 1
       # removed virtual_ip_addr
        broker_virtual_hostname   = @deployment.load_balancers[0].broker_cluster_virtual_host
        infra_host_list << " { hostname => '#{broker_virtual_hostname}', ipaddr => '#{broker_virtual_ip_address}'}"
      end
    end
  end
else
  @env_map['CONF_NAMED_HOSTNAME']     = @deployment.dns.dns_host_name
  @env_map['CONF_NAMED_IP_ADDR']      = @deployment.dns.dns_host_ip
  @env_map['CONF_BIND_KEY']           = @deployment.dns.dnssec_key
end
if @deployment.brokers.length == 1
  @env_map['CONF_BROKER_HOSTNAME']    = @deployment.brokers[0].host
  @env_map['CONF_BROKER_IP_ADDR']     = @deployment.brokers[0].ip_addr
else
  @env_map['CONF_BROKER_HOSTNAME']    = @deployment.load_balancers[0].broker_cluster_virtual_host
  @env_map['CONF_BROKER_IP_ADDR']     = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
end
if @deployment.dbservers.length == 1
  @env_map['CONF_DATASTORE_HOSTNAME']                     = @deployment.dbservers[0].host
end
if @deployment.msgservers.length == 1
  @env_map['CONF_ACTIVEMQ_HOSTNAME']                      = @deployment.msgservers[0].host
end

if @deployment.nodes.length == 1
  @env_map['CONF_NODE_HOSTNAME']                          = @deployment.nodes[0].host
  @env_map['CONF_NODE_IP_ADDR']                           = @deployment.nodes[0].ip_addr
  @env_map['CONF_INTERFACE']                              = @deployment.nodes[0].ip_interface
end

@cred_map = {
    :mcollective_user              => 'CONF_MCOLLECTIVE_USER',
    :mcollective_password          => 'CONF_MCOLLECTIVE_PASSWORD',
    :mongodb_broker_user           => 'CONF_MONGODB_BROKER_USER',
    :mongodb_broker_password       => 'CONF_MONGODB_BROKER_PASSWORD',
    :mongodb_admin_user            => 'CONF_MONGODB_ADMIN_USER',
    :mongodb_admin_password        => 'CONF_MONGODB_ADMIN_PASSWORD',
    :openshift_user                => 'CONF_OPENSHIFT_USER1',
    :openshift_password            => 'CONF_OPENSHIFT_PASSWORD1',
}
# And finally, gear sizes.
@env_map['CONF_VALID_GEAR_SIZES']          = @deployment.broker_global.valid_gear_sizes.join(',')
@env_map['CONF_DEFAULT_GEAR_CAPABILITIES'] = @deployment.broker_global.user_default_gear_sizes.join(',')
@env_map['CONF_DEFAULT_GEAR_SIZE']         = @deployment.broker_global.default_gear_size

# Make the templates

ordered_brokers     = @deployment.brokers.sort_by{ |h| h.host }
ordered_dbservers   = @deployment.dbservers.sort_by { |h| h.host }
ordered_msgservers  = @deployment.msgservers.sort_by { |h| h.host }

host_installation_order.each do |host_instance|
  puts "\nGenerating template for '#{host_instance.host}'"




# Deploy a nameserver on the first host that completes the install process.
  if @deployment.dns.deploy_dns? and host_instance.is_nameserver? and not deploy_dns(host_instance)
    puts "The installer could not successfully configure a DNS server on #{host_instance.host}. Exiting"
    exit 1
  end


##
## Individual Host Configuration: These are per-host configurations for OpenShift.
##
  host_config                             = @env_map.clone
  host_config['CONF_INSTALL_COMPONENTS']  = components_list(host_instance) # Not sure if this is a problem.

  @cred_map.each do |host_var, env_var|
    value = host_instance.send(host_var)
    if not value.nil?
      host_config[env_var] = value
    end
  end
  # Handle HA Brokers
  if @deployment.brokers.length > 1
    # DNS is used to configure the load balancer
    if host_instance.is_nameserver?
      host_config['CONF_INSTALL_COMPONENTS']        = %w[ named ]
    end
    # Brokers
    if host_instance.is_broker?
      host_config['CONF_BROKER_HOSTNAME']              = host_instance.host
      host_config['CONF_BROKER_IP_ADDR']               = host_instance.ip_addr
    else
      # Non-broker hosts talk to the Brokers through the load balancer.
      host_config['CONF_BROKER_HOSTNAME']              = @deployment.load_balancers[0].broker_cluster_virtual_host
      host_config['CONF_BROKER_IP_ADDR']               = @deployment.load_balancers[0].broker_cluster_virtual_ip_addr
    end
  end

  # Handle HA DBServers
  if @deployment.dbservers.length > 1
    if host_instance.is_dbserver? or host_instance.is_broker?
      host_config['CONF_MONGODB_REPLSET']           = "ose" # Explictly defines the name of the replica set.
      host_config['CONF_DATASTORE_REPLICANTS']      = '[' + ordered_dbservers.map{ |h|  "'#{h.ip_addr}:#{@mongodb_port}'"}.join(',') + ']'
    end
    if host_instance.is_dbserver?
      host_config['CONF_MONGODB_REPLSET']              = "ose" # Explictly defines the anme of the replica set.
      host_config['CONF_DATASTORE_HOSTNAME']           = host_instance.host
      ## Need to run configure_datastore_add_replicants after configure_openshift
      host_config['CONF_MONGODB_KEY']                  = @deployment.db_replica_primaries[0].mongodb_replica_key
    end
  end

  # Handle HA MsgServers
  if @deployment.msgservers.length > 1
    if host_instance.is_msgserver? or host_instance.is_broker? or host_instance.is_node?
      host_config['CONF_ACTIVEMQ_REPLICANTS']    = '[' + ordered_msgservers.map{ |h| "'#{h.host}'"}.join(',')  + ']'
    end
    if host_instance.is_msgserver?
      host_config['CONF_ACTIVEMQ_HOSTNAME']           = host_instance.host
      host_config['CONF_ACTIVEMQ_ADMIN_PASSWORD']     = host_instance.msgserver_cluster_password
    end
  end
  ######################################
  ## Create the hostfile for each host.#
  ######################################

  @openshift_installer = "openshift.sh"
  build_config(host_instance, host_config)
  # Write it to each host.
end
close_all_ssh_sessions

############################################
# Stage 6: Run the Deployments in Parallel #
############################################

@child_pids = {}
puts "\n"
host_installation_order.each do |host_instance|
    @child_pids[host_instance.host] = Process.fork do
        puts "#{host_instance.host}: Running deployment for host"
        copy_template    = `scp #{@hostfile} root@#{host_instance.host}:/tmp/host_config_#{host_instance.host}.sh`
        copy_openshiftsh = `scp #{File.dirname(__FILE__)}/openshift.sh root@#{host_instance.host}:/tmp/openshift.sh`
        puts copy_openshiftsh
        # ADD ERROR MESSAGES
    if @keep_hostfile
        puts "User specified that the openshift module is already installed."
    else
        # Uninstall the existing hostfile configuration.
    end

    # Reset the yum repos
    puts "#{host_instance.host}: Cleaning yum repos."
    yum_clean = host_instance.exec_on_host!('yum clean all')
    if not yum_clean[:exit_code] == 0
        display_error_info(host_instance, yum_clean, 'Failed to clean yum repo database')
        exit 1
    end

    # Set permissions for hostfile + openshift.sh.
    puts "#{host_instance.host}: Setting permissions for hostfile and openshift.sh."
    set_hostfile_permissions = host_instance.exec_on_host!("sh -c 'chmod +x /tmp/host_config_#{host_instance.host}.sh'")
    if not set_hostfile_permissions[:exit_code] == 0
      display_error_info(host_instance, set_hostfile_permissions, 'Failed to set permissions on hostfile.')
      exit 1
    end

    # Run the hostfile...
    puts "#{host_instance.host}: Running the deployment. This step may take up to an hour."

    run_hostfile = host_instance.exec_on_host!("sh -c 'cd /tmp && ./host_config_#{host_instance.host}.sh'")
    if not run_hostfile[:exit_code] == 0
      display_error_info(host_instance, run_hostfile, 'Failed to run the hostfile.')
      exit 1
    end
    if not @keep_assets
        puts "#{host_instance.host}: Cleaning up temporary files."
        clean_up = host_instance.exec_on_host!("rm /tmp/#{@hostfile}")
        if not clean_up[:exit_code] == 0
            puts "#{host_instance.host}: Clean up of /tmp/#@hostfile} failed; please remove this file manually."
        end
    else
        puts "#{host_instance.host}: Keeping /tmp/#{@hostfile}"
    end
    if not host_instance.localhost?
        host_instance.close_ssh_session
    end

    # Bail out of the fork
    exit
    end
end

# Wait for the parallel installs to finsih, inspect results.
procs = Process.waitall
host_failures = []
host_installation_order.each do |host_instance|
    host_pid = @child_pids[host_instance.host]
    host_proc = procs.select{ |process| process[0] == host_pid }[0]
    if not host_proc.nil? and not host_proc[1].exitstatus == 0
        host_failures << host_instance.host + ' (' + host_proc[1].exitstatus.to_s + ')'
    else
        puts "Could not determine deployment status for host #{host_instance.host}"
    end
end

if host_failures.length == 0
    puts "\nHost deployments completed successfully."
else
    if host_failures.length == host_installation_order.length
        puts "None of the host deployments succeeded:"
    else
        puts "The following host deployments failed:"
    end
    host_failures.each do |hostname|
        puts " * #{hostname}"
    end
    puts "Please investigate these failures by starting with the /tmp/openshift-deploy.log file on each host. \N Exiting installation with errors."
    exit 1
end


#########################################
# Stage 7: (Re)Start OpenShift Services #
#########################################\

if @target_node.nil?
  puts "\nRestarting services in dependency order."
  manage_service :named,                    @deployment.nameservers
  manage_service :mongod,                   @deployment.dbservers
  if @deployment.dbservers.length > 1
    configure_mongodb_replica_set
    puts "\n"
  end
  manage_service 'ruby193-mcollective',      @deployment.nodes, :stop
  manage_service :activemq,                  @deployment.msgservers
  manage_service 'ruby193-mcollective',      @deployment.nodes, :start
  manage_service 'openshift-broker',         @deployment.brokers
  manage_service 'openshift-console',        @deployment.brokers
  @deployment.nodes.each { |h| h.exec_on_host!('/etc/cron.minutely/openshift-facts') }
else
  @target_node.exec_on_host!('/etc/cron.minutely/openshift-facts')
end


###############################
# Stage 8: Post Install Tasks #
###############################
if @target_node.nil?
  puts "\nNow performing post-installation tasks."

  # The post-install work can all be run from any broker.
  broker = @deployment.brokers[0]
  @deployment.districts.each do |district|
    district_cmd = "oo-admin-ctl-district -c create -n #{district.name} -p #{district.gear_size}"
    create_district = broker.exec_on_host!(district_cmd)
    if create_district[:exit_code] == 0
      puts "\nSuccessfully created district '#{district.name}'."
      print "Attempting to add compatible Nodes to #{district.name} district..."
      node_cmd = "oo-admin-ctl-district -c add-node -n #{district.name} -a"
      add_node = broker.exec_on_host!(nokde_cmd)
      if add_node[:exit_code] == 0
        puts "succeeded."
      else
        puts "failed.\nYou will need to run the following manually from any Broker to add this node:\n\n\t#{node-cmd}"
      end
    else
      puts "Failed to create district '#{district.name}'.\n You will need to run the following manually on a Broker to create the district:\n\n\t#{district_cmd}\n\nThen you will need to runt he add-node command fro each associated node:\n\n\too-admin-ctl-district -c add-node -n #{district.name} i <node_hostname>"
    end
  end

  puts "\nAttempting to register available cartridge types with Broker(s)."
  carts_cmd = 'oo-admin-ctl-cartridge -c import-node --activate'
  set_carts = broker.exec_on_host!(carts_cmd)
  if not set_carts[:exict_code] == 0
    puts "Could not register cartridge types with Broker(s).\nLog into any Broker and attempt to register the carts with this command:\n\n\t#{carts_cmd}\n\n"
  else
    puts "Cartridge registrations succeeded."
  end
end

close_all_ssh_sessions

host = @deployment.hosts[0]
puts "\n\nThe following user / password combinations were created during the configuration:"
puts "Web console:    #{host.openshift_user} / #{host.openshift_password}"
puts "MCollective:    #{host.mcollective_user} / #{host.mcollective_password}"
puts "MongoDB Admin:  #{host.mongodb_admin_user} / #{host.mongodb_admin_password}"
puts "MongoDB User:   #{host.mongodb_broker_user} / #{host.mongodb_broker_password}"
puts "\n\nBe sure to record these somewhere safe for future use.\n\n"

puts "Deployment successful. Exiting installer."

exit

