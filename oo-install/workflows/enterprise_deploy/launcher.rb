#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'
require 'installer'
require 'installer/helpers'
require 'installer/config'
require 'installer/deployment'
require 'installer/host_instance'
require 'tempfile'

include Installer::Helpers

######################################
# Stage 1: Handle ENV and ARGV input #
######################################
@mongodb_port     = 27017
@logfile          = '/tmp/openshift-deploy.log'

# Check ENV for an alternate config file location.
if ENV.has_key?('OO_INSTALL_CONFIG_FILE')
  @config_file = ENV['OO_INSTALL_CONFIG_FILE']
else
  @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# Check to see if we need to preserve generated files.
@keep_assets = ENV.has_key?('OO_INSTALL_KEEP_ASSETS') and ENV['OO_INSTALL_KEEP_ASSETS'] == 'true'

@debug = false
if ENV.has_key?('OO_INSTALL_DEBUG') and ENV['OO_INSTALL_DEBUG'] == 'true'
  @debug = true
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
end

#############################################
# Stage 2: Load and check the configuration #
#############################################
# Set some globals
set_context(:ose)
set_mode(true)
set_advanced_repo_config(true)

def get_deployment
  openshift_config = Installer::Config.new(@config_file)
  if not openshift_config.is_valid?
    puts "Could not process config file at '#{@config_file}'. Exiting."
    exit 1
  end

  deployment = openshift_config.get_deployment
  errors = deployment.is_valid?(:full)
  if errors.length > 0
    puts "The OpenShift deployment configuration has the following errors:"
    errors.each do |error|
      puts "  * #{error.message}"
    end
    puts "Rerun the installer to correct these errors."
    exit 1
  end
  deployment
end

@deployment = get_deployment

@subscription = @deployment.config.get_subscription
errors = @subscription.is_valid?(:full)
if errors.length > 0
  puts "The OpenShift subscription configuration has the following errors:"
  errors.each do |error|
    puts "  * #{error}"
  end
  puts "Rerun the installer to correct these errors."
  exit 1
end

@tmpdir = Dir.mktmpdir('oo-install')

# Store the hostfiles per hostname
@hostfiles = {}

@states = [ :new, :prepared, :installed, :host_configured, :configured, :rs_complete, :complete, :validated ]
@steps = [ [ :prepare      , { :name => 'Prepare',
                               :actions => [ 'validate_preflight', 'configure_repos' ],
                               :start_states => [ @states[0] ],
                               :start_message => 'Configuring package repositories.',
                               :success_state => @states[1],
                               :success_message => 'Completed configuring package repositories.',
                               :reentrant => true } ],
            [ :install     , { :name => 'Install RPMs',
                               :actions => [ 'install_rpms' ],
                               :start_states => [ @states[1] ],
                               :start_message => 'Installing RPMs. This step can take up to an hour.',
                               :success_state => @states[2],
                               :success_message => 'Completed installing RPMs.',
                               :reentrant => true } ],
            [ :conf_host   , { :name => 'Configure Host',
                               :actions => [ 'configure_host' ],
                               :start_states => [ @states[2] ],
                               :start_message => 'Configuring host.',
                               :success_state => @states[3],
                               :success_message => 'Completed configuring host.',
                               :reentrant => true } ],
            [ :configure   , { :name => 'Configure OpenShift',
                               :actions => [ 'configure_openshift' ],
                               :start_states => [ @states[3] ],
                               :start_message => 'Configuring OpenShift.',
                               :success_state => @states[4],
                               :success_message => 'Completed configuring OpenShift.',
                               :reentrant => false } ],
            [ :conf_rs     , { :name => 'Configure Replica Sets',
                               :actions => [ 'configure_datastore_add_replicants' ],
                               :start_states => [ @states[4] ],
                               :start_message => 'Configuring MongoDB replica set.',
                               :success_state => @states[5],
                               :success_message => 'Completed configuring MongoDB replica set.',
                               :reentrant => false } ],
            [ :post_deploy , { :name => 'Post Deploy',
                               :actions => [ 'post_deploy' ],
                               :start_states => [ @states[4], @states[5] ],
                               :start_message => 'Performing post deploy steps.',
                               :success_state => @states[6],
                               :success_message => 'Completed post deploy steps.',
                               :reentrant => true } ],
            [ :validate    , { :name => 'Validate',
                               :actions => [ 'run_diagnostics' ],
                               :start_states => [ @states[6] ],
                               :start_message => 'Validating installation.',
                               :success_state => @states[7],
                               :success_message => 'Completed validation.',
                               :reentrant => true } ],
]
@abort_regex=/^OpenShift: Aborting Installation./

###############################################
# Stage 3: Define some locally useful methods #
###############################################
def step_by_key key
  @steps.each do |s|
    return s[1] if s[0] == key
  end
  return nil
end

def components_list host_instance
  values = []
  host_instance.roles.each do |role|
    # this addresses an error in older config files
    case role
    when :dbserver
      role_value = 'datastore'
    when :msgserver
      role_value = 'activemq'
    when :nameserver
      role_value = 'named'
    else
      role_value = role.to_s
    end
    values << role_value
  end
  values.sort.map{ |r| "#{r}"}.join(',')
end

def display_error_info host_instance, exec_info, message
  puts [
    "#{host_instance.host}: #{message}",
    "Output: #{exec_info[:stdout]}",
    "Error: #{exec_info[:stderr]}",
    "Exiting installation on this host.",
  ].join("\n#{host_instance.host}: ")
end

def close_all_ssh_sessions
  @deployment.hosts.each do |host_instance|
    host_instance.close_ssh_session unless host_instance.localhost?
  end
end

def utility_install_order
  @utility_install_order ||= [:nameservers, :dbservers, :msgservers, :brokers, :nodes]
end

# The hostfile contains the environment variables for each host in a deployment.
# After setting the environment variables, it calls openshift.sh to complete
# installation.
def build_hostfile(hostname, host_config)
  hostfile = Tempfile.new(["host_config_","_#{hostname}.sh"], @tmpdir)
  hostfile << "#!/bin/bash\n"
  hostfile << "# Host configuration for OpenShift.\n"
  hostfile << "set -e\n"
  host_config.each do |key, val|
    hostfile << "export #{key}='#{val}'\n"
  end
  hostfile << "./openshift.sh\n"
  hostfile.close
  @hostfiles[hostname]=hostfile.path
end

def build_host_config(host_instance, step_props)
  host_config = {}

  # configure subscription info
  # subscription values are currently passed in via the command line
  { 'subscription_type'   => 'CONF_INSTALL_METHOD',
    'rh_username'         => 'CONF_RHN_USER',
    'rh_password'         => 'CONF_RHN_PASS',
    'sm_reg_pool'         => 'CONF_SM_REG_POOL',
    'rhn_reg_actkey'      => 'CONF_RHN_REG_ACTKEY',
    'cdn_repo_base'       => 'CONF_CDN_REPO_BASE',
    'jboss_repo_base'     => 'CONF_JBOSS_REPO_BASE',
    'rhel_repo'           => 'CONF_RHEL_REPO',
    'rhscl_repo_base'     => 'CONF_RHSCL_REPO_BASE',
    'ose_repo_base'       => 'CONF_OSE_REPO_BASE',
    'rhel_extra_repo'     => 'CONF_RHEL_EXTRA_REPO',
    'jbosseap_extra_repo' => 'CONF_JBOSSEAP_EXTRA_REPO',
    'jbossews_extra_repo' => 'CONF_JBOSSEWS_EXTRA_REPO',
    'rhscl_extra_repo'    => 'CONF_RHSCL_EXTRA_REPO',
    'ose_extra_repo'      => 'CONF_OSE_EXTRA_REPO',
  }.each do |env_var, sh_var|
    env_key = "OO_INSTALL_#{env_var.upcase}"
      host_config[sh_var] = ENV[env_key] if ENV.has_key?(env_key)
  end

  # Set variables used by all steps
  host_config['CONF_INSTALL_COMPONENTS']  = components_list(host_instance)
  host_config['CONF_ACTIONS'] = step_props[:actions].join(',')
  host_config['CONF_DOMAIN'] = @deployment.dns.app_domain
  host_config['CONF_INTERFACE'] = host_instance.ip_interface

  #TODO: add logic to assistant for other unused variables
  #CONF_NO_NTP (all)
  #CONF_KEEP_NAMESERVERS (all)
  #CONF_KEEP_HOSTNAME (all)
  #CONF_FORWARD_DNS (nameserver only)
  #CONF_BIND_KEYALGORITHM (nameserver, broker)
  #CONF_BIND_KEYSIZE (nameserver only)
  #CONF_BIND_KRB_KEYTAB (broker only)
  #CONF_BIND_KRB_PRINCIPAL (broker only)

  if @deployment.dns.deploy_dns?
    host_config['CONF_NAMED_IP_ADDR'] = @deployment.nameservers.first.ip_addr
    if @deployment.dns.register_components?
      host_config['CONF_HOSTS_DOMAIN'] = @deployment.dns.component_domain
    else
      host_config['CONF_HOSTS_DOMAIN'] = @deployment.dns.app_domain
    end
  else
    host_config['CONF_NAMED_IP_ADDR'] = @deployment.dns.dns_host_ip
  end

  if host_instance.roles.include? :nameserver
    host_config['CONF_NAMED_HOSTNAME'] = host_instance.host
    host_config['CONF_BIND_KEY'] = @deployment.dns.dnssec_key unless @deployment.dns.dnssec_key.nil?
    if @deployment.dns.register_components? && @deployment.hosts.count > 1
      named_entries = @deployment.hosts.map{ |i| "#{i.host}:#{i.ip_addr}" if i.host != host_instance.host }.compact
      if @deployment.brokers.count > 1
        named_entries += @deployment.brokers.map{ |i| "#{@deployment.broker_global.broker_hostname}:#{i.ip_addr}"}
      end
      host_config['CONF_NAMED_ENTRIES'] = named_entries.join(',')
    else
      host_config['CONF_NAMED_ENTRIES'] = 'NONE'
    end
  end

  if host_instance.roles.include? :broker
    host_config['CONF_BIND_KEY'] = @deployment.dns.dnssec_key unless @deployment.dns.dnssec_key.nil?
    host_config['CONF_BROKER_HOSTNAME'] = host_instance.host
    host_config['CONF_VALID_GEAR_SIZES'] = @deployment.broker_global.valid_gear_sizes.join(',')
    host_config['CONF_DEFAULT_GEAR_CAPABILITIES'] = @deployment.broker_global.user_default_gear_sizes.join(',')
    host_config['CONF_DEFAULT_GEAR_SIZE'] = @deployment.broker_global.default_gear_size
    host_config['CONF_DEFAULT_DISTRICTS'] = 'false'
    host_config['CONF_DISTRICT_MAPPINGS'] = @deployment.districts.map{ |d| "#{d.name}:#{d.node_hosts.join(',')}" }.join(';')
    host_config['CONF_OPENSHIFT_USER1'] = host_instance.openshift_user
    host_config['CONF_OPENSHIFT_PASSWORD1'] = host_instance.openshift_password
    host_config['CONF_BROKER_AUTH_SALT'] = host_instance.broker_auth_salt
    host_config['CONF_BROKER_SESSION_SECRET'] = host_instance.broker_session_secret
    host_config['CONF_CONSOLE_SESSION_SECRET'] = host_instance.console_session_secret
    host_config['CONF_BROKER_AUTH_PRIV_KEY'] = host_instance.broker_auth_priv_key
  elsif @deployment.brokers.count == 1
    host_config['CONF_BROKER_HOSTNAME'] = @deployment.brokers.first.host
  else
    host_config['CONF_BROKER_HOSTNAME'] = @deployment.broker_global.broker_hostname
  end

  # Datastore settings only needed for dbserver and broker roles
  unless ([:dbserver, :broker] & host_instance.roles).empty?
    if host_instance.roles.include? :dbserver
      host_config['CONF_DATASTORE_HOSTNAME'] = host_instance.host
      host_config['CONF_MONGODB_ADMIN_USER'] = host_instance.mongodb_admin_user
      host_config['CONF_MONGODB_ADMIN_PASSWORD'] = host_instance.mongodb_admin_password
      if @deployment.dbservers.count > 1
        host_config['CONF_MONGODB_REPLSET'] = host_instance.mongodb_replica_name
        host_config['CONF_MONGODB_KEY'] = host_instance.mongodb_replica_key
      end
    end

    host_config['CONF_DATASTORE_REPLICANTS'] = @deployment.dbservers.map{ |i| "#{i.host}:#{@mongodb_port}" }.join(',')
    host_config['CONF_MONGODB_BROKER_USER'] = host_instance.mongodb_broker_user
    host_config['CONF_MONGODB_BROKER_PASSWORD'] = host_instance.mongodb_broker_password
  end

  # ActiveMQ settings only needed for msgserver, broker, and node roles
  unless ([:msgserver, :broker, :node] & host_instance.roles).empty?
    if host_instance.roles.include? :msgserver
      host_config['CONF_ACTIVEMQ_HOSTNAME'] = host_instance.host
      if @deployment.msgservers.count > 1
        host_config['CONF_ACTIVEMQ_AMQ_USER_PASSWORD'] = host_instance.msgserver_cluster_password
      end
    end

    host_config['CONF_ACTIVEMQ_REPLICANTS'] = @deployment.msgservers.map { |i| i.host }.join(',')
    host_config['CONF_MCOLLECTIVE_USER'] = host_instance.mcollective_user
    host_config['CONF_MCOLLECTIVE_PASSWORD'] = host_instance.mcollective_password
  end

  if host_instance.roles.include? :node
    host_config['CONF_NODE_HOSTNAME'] = host_instance.host
    host_config['CONF_NODE_IP_ADDR'] = host_instance.ip_addr
    host_config['CONF_NODE_PROFILE'] = @deployment.get_district_by_node(host_instance).gear_size
  end

  build_hostfile host_instance.host, host_config
end

# Execute step on hosts
def execute_step_on_hosts(host_list, step)
  @child_pids = {}
  puts "\n"
  host_list.each do |host_instance|
    @child_pids[host_instance.host] = Process.fork do
      msg_prefix = "#{host_instance.host} #{step[:step_name]}: "

      puts "#{msg_prefix}#{step[:start_message]}"

      hostfile = @hostfiles[host_instance.host]
      hostfilename = File.basename(hostfile)
      remotehostfile = "/tmp/#{hostfilename}"
      openshiftsh = "#{File.dirname(__FILE__)}/openshift.sh"
      remoteopenshiftsh = "/tmp/openshift.sh"
      if host_instance.localhost?
        copy_template    = `cp #{hostfile} #{remotehostfile}`
        # TODO: do not use predictable path for openshift.sh
        copy_openshiftsh = `cp #{openshiftsh} #{remoteopenshiftsh}`
        # TODO: check return state of cp command
      else
        copy_template    = `scp #{hostfile} #{host_instance.user}@#{host_instance.ssh_host}:#{remotehostfile}`
        # TODO: do not use predictable path for openshift.sh
        copy_openshiftsh = `scp #{openshiftsh} #{host_instance.user}@#{host_instance.ssh_host}:#{remoteopenshiftsh}`
        # TODO: check return state of scp command
      end
      # Set permissions for hostfile + openshift.sh.
      puts "#{msg_prefix}Setting permissions for hostfile and openshift.sh." if @debug
      set_hostfile_permissions = host_instance.exec_on_host!("chmod 0700 #{remotehostfile} #{remoteopenshiftsh}")
      if not set_hostfile_permissions[:exit_code] == 0
        display_error_info(host_instance, set_hostfile_permissions, 'Failed to set permissions on hostfile.')
        exit 1
      end

      puts "#{msg_prefix}Running the hostfile" if @debug

      run_hostfile = host_instance.exec_on_host!("cd /tmp && ./#{hostfilename} |& tee -a #{@logfile} | stdbuf -oL -eL grep -i '^OpenShift:'\n")
      if run_hostfile[:stdout].match(@abort_regex)
        display_error_info(host_instance, run_hostfile, 'Failed to run the hostfile.')
        exit 1
      else
        output=run_hostfile[:stdout].split("\n").map{ |line| "\t#{line}"}.join("\n")
        puts "#{host_instance.host}: \n#{output}\n"
      end

      if not @keep_assets
        puts "#{msg_prefix}Cleaning up temporary files." if @debug
        clean_up = host_instance.exec_on_host!("rm #{remotehostfile}")
        if not clean_up[:exit_code] == 0
          puts "#{msg_prefix}Clean up of #{remotehostfile} failed; please remove this file manually."
        end
        clean_up = host_instance.exec_on_host!("rm #{remoteopenshiftsh}")
        if not clean_up[:exit_code] == 0
          puts "#{msg_prefix}Clean up of #{remoteopenshiftsh} failed; please remove this file manually."
        end
      else
        puts "#{msg_prefix}Keeping #{remotehostfile} and #{remoteopenshiftsh}"
      end
      host_instance.close_ssh_session unless host_instance.localhost?
      puts "#{msg_prefix}#{step[:success_message]}"

      # Bail out of the fork
      exit
    end
  end

  # Wait for the parallel installs to finsih, inspect results.
  procs = Process.waitall
  host_failures = []
  host_list.each do |host_instance|
    host_pid = @child_pids[host_instance.host]
    host_proc = procs.select{ |process| process[0] == host_pid }[0]
    if not host_proc.nil? and not host_proc[1].exitstatus == 0
      host_failures << host_instance.host + ' (' + host_proc[1].exitstatus.to_s + ')'
      unless step[:reentrant]
        host_instance.install_status = :failed
        @deployment.save_to_disk!
      end
    else
      host_instance.install_status = step[:success_state]
      @deployment.save_to_disk!
    end
  end

  if host_failures.length == 0
    puts "\nStep #{step[:name]} completed successfully."
  else
    if host_failures.length == host_list.length
      puts "None of the host deployments succeeded:"
    else
      puts "The following host deployments failed:"
    end
    host_failures.each do |hostname|
      puts " * #{hostname}"
    end
    puts "Please investigate these failures by starting with the #{@logfile} file on each host. \N Exiting installation with errors."
    exit 1
  end
end

############################################
# Stage 4: Workflow-specific configuration #
############################################
hosts_for_installation = []
# If we are using the Add a node workflow only act on the selected nodes (if the Node to add exists in config)
if not @target_node_hostname.nil?
  @deployment.nodes.select{ |h| h.roles.count == 1 and h.host = @target_node_hostname }.each do |host_instance|
    @target_node = host_instance
    hosts_for_installation << host_instance
    break
  end
  if @target_node.nil?
    puts "The list of nodes in the config file at #{@config_file} does not contain an entry for #{@target_node_hostname}. Exiting."
    exit 1
  end
else
  hosts_for_installation = @deployment.hosts
end

############################################
# Stage 5: Run the Deployments #
############################################
@steps.each do |s|
  step_key = s[0]
  step_props = s[1]
  # filter out hosts that have a state other than start_states
  host_instances = hosts_for_installation.select { |i| step_props[:start_states].include? i.install_status }
  next if host_instances.empty?

  # an array of hashes (with a single key for the step name) [{step: [host_instances]}]
  host_lists = []

  case step_key
  when :conf_rs
    # :conf_rs is a special state that is only run on a single mongo
    # host after the configure step has been completed
    next
  when :post_deploy
    # Post Deploy is only run on the first broker
    host_lists = [ { step_key => host_instances.select { |i| i.host == @deployment.brokers.first.host } } ]

    # push other hosts to :success_state
    (host_instances - host_lists.first[step_key]).each do |host_instance|
      host_instance.install_status = step_props[:success_state]
    end
    @deployment.save_to_disk!
  when :validate
    # Validate should only be run on brokers and nodes
    host_lists = [ { step_key => host_instances.select { |i| !([:broker,:node] & i.roles).empty? } } ]

    # push other hosts to :success_state
    (host_instances - host_lists.first[step_key]).each do |host_instance|
      host_instance.install_status = step_props[:success_state]
    end
    @deployment.save_to_disk!
  when :configure
    seen_hosts = []
    utility_install_order.each do |role_order|
      hosts = host_instances & @deployment.send(role_order)
      unless hosts.empty?
        hosts_to_add = hosts - seen_hosts
        unless hosts_to_add.empty?
          host_lists << { step_key => hosts_to_add }
          seen_hosts += hosts_to_add
        end
        if role_order == :dbservers and @deployment.dbservers.count > 1
          host_lists << { :conf_rs => [@deployment.dbservers.first] }
        end
      end
    end
  when :conf_host
    # :install has been run, if we are configuring DNS, then generate a bind_key
    if @deployment.nameservers.count > 0
      # TODO need to verify that this works for local runs as well
      result = @deployment.nameservers.first.exec_on_host!(%Q[tmpdir=`mktemp -d`; dnssec-keygen -a HMAC-SHA256 \
                                                              -b 256 -n USER -r /dev/urandom -K ${tmpdir} \
                                                              ose > /dev/null; cat ${tmpdir}/Kose*.key; \
                                                              rm -rf ${tmpdir}])
      if result[:exit_code] != 0
        puts 'Error generating bind key for deployment'
      else
        key=result[:stdout].chomp.split(' ').last
        @deployment.dns.dnssec_key = key
        @deployment.save_to_disk!
      end
    end

    # Run the :conf_host step against all host_instances
    host_lists = [ { step_key => host_instances } ]
  else
    host_lists = [ { step_key => host_instances } ]
  end

  host_lists.each do |step_to_host_instances|
    s_key, s_instances = step_to_host_instances.shift
    s_instances.each do |host_instance|
      build_host_config host_instance, step_by_key(s_key)
    end

    # Close any SSH sessions that got opened.
    # for deployment jobs, we don't want to be forking with open sessions
    close_all_ssh_sessions
    execute_step_on_hosts(s_instances, step_by_key(s_key))
  end
end

# remove the temporary directory
# TODO should really wrap this in an ensure to make sure it is cleaned up properly after each run,
# possibly keep it around if OO_KEEP_ASSETS is true
FileUtils.remove_entry_secure @tmpdir

#TODO summarize system state after all steps have been run
#     also, actually validate that all steps are run before declaring success
exit 1

#TODO need to collect passwords for all services, which could be spread out across multiple host configs
host = @deployment.hosts.first
puts "\n\nThe following user / password combinations were created during the configuration:"
puts "Web console:    #{host.openshift_user} / #{host.openshift_password}"
puts "MCollective:    #{host.mcollective_user} / #{host.mcollective_password}"
puts "MongoDB Admin:  #{host.mongodb_admin_user} / #{host.mongodb_admin_password}"
puts "MongoDB User:   #{host.mongodb_broker_user} / #{host.mongodb_broker_password}"
puts "\n\nBe sure to record these somewhere safe for future use.\n\n"

puts "Deployment successful. Exiting installer."

exit

