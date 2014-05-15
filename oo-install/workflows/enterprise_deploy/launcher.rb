#!/usr/bin/env ruby

require 'yaml'
require 'tempfile'
require 'net/ssh'
require 'installer/helpers'
require 'installer/config'
require 'installer/deployment'
require 'installer/host_instance'

COMPONENT_INSTALL_ORDER = %w[ named datastore activemq broker node ]
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

# Check ENV for an alternate config file location.
@config_file = ENV['OO_INSTALL_CONFIG_FILE'] || ENV['HOME'] + '/.openshift/oo-install-cfg.yml'

# Check ENV for "keep assets" flag
@keep_assets = ENV.has_key?('OO_INSTALL_KEEP_ASSETS') and ENV['OO_INSTALL_KEEP_ASSETS'] == 'true'

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
  return "''" if str.nil? or str.empty?

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

def state_already?(host, state)
  INSTALL_STATES.index(state) <= INSTALL_STATES.index(host['state'] || 'new')
end
def save_and_exit(code = 0)
  File.open(@config_file, 'w') {|file| file.write @config.to_yaml}
  exit code
end

# copied from http://stackoverflow.com/a/1076445/262768 and modified
def fork_and_run(job, &block)
  # run a job in forked child and retrieve the results into the job object.
  r, w = IO.pipe

  pid = fork do
    r.close
    result = block.call
    Marshal.dump(result, w)
    exit!(0) # skips exit handlers.
  end

  w.close
  job[:result] = r
end

def read_fork_result(job)
  return Hash.new unless job.is_a?(Hash) && (r = job[:result])
  return r unless r.is_a? IO
  job[:result] = Marshal.load(r) || Hash.new
end

def wait_and_report(jobs, step) # bails if any fail
  Process.waitall
  succeeded = jobs.select {|job| read_fork_result(job)[:success]}
  failed = jobs - succeeded
  unless succeeded.empty?
    puts "\nInstall step '#{step}' succeeded for:"
    succeeded.each do |host|
      puts "  * #{host['ssh_host']}"
      host.delete :result
      host['state']=INSTALL_STATES[INSTALL_STEPS.index step]
    end
  end
  unless failed.empty?
    puts "\n---------------------------------------"
    puts "Install step '#{step}' FAILED for:"
    failed.each do |host|
      puts "  * #{host['ssh_host']} (#{host['host']})"
      puts host[:result][:message]
      host.delete :result
    end
    puts "It is safe to run this deployment again after problem resolution."
    puts "--------------------------------------------"
    save_and_exit 1
  end
end

def run_on_host(host, step)
  puts "Running '#{step}' step on #{host['ssh_host']} (#{host['host']})\n"

  ssh_target = "#{host['user']}@#{host['ssh_host']}"
  ssh_path = "#{host['user']}@#{host['ssh_host']}:/tmp"
  hostfile = "oo_install_configure_#{host['ssh_host']}.sh"
  logfile = "/tmp/openshift-deploy.log"
  sudo = host['user'] == 'root' ? '' : 'sudo -- '

  @env_map['CONF_INSTALL_COMPONENTS'] = components_list(host)
  @env_map['CONF_ACTIONS'] = INSTALL_ACTIONS[INSTALL_STEPS.index step]

  # Cleanup host specific env vars from any previous runs
  host['roles'].each do |role|
    @role_map[role].each do |ose_role|
      ose_role.values.each do |env_var|
        @env_map.delete(env_var)
      end
    end
  end

  # Set host specific env vars
  host['roles'].each do |role|
    @role_map[role].each do |ose_role|
      ose_role.each do |config_var, env_var|
        case config_var
        when 'env_hostname'
          @env_map[env_var] = host['host']
        when 'env_ip_addr'
          if env_var == 'CONF_NAMED_IP_ADDR' and host.has_key?('named_ip_addr')
            @env_map[env_var] = host['named_ip_addr']
          else
            @env_map[env_var] = host['ip_addr']
          end
        when 'district_mappings'
          @env_map[env_var] = host['district_mappings'].map {|district,nodes| "#{district}:#{nodes.join(',')}"}.join(';')
        when 'conf_default_districts'
          @env_map[env_var] = 'false'
        else
          @env_map[env_var] = host[config_var] unless host[config_var].nil?
        end
      end
    end

    # Set needed env variables that are not explicitly configured on the host
    @hosts.values.each do |host_info|
      # Both the broker and node need to set the activemq hostname, but it is not stored in the config
      if ['broker','node'].include?(role) and host_info['roles'].include?('msgserver')
        @env_map['CONF_ACTIVEMQ_HOSTNAME'] = host_info['host']
      end

      # The broker needs to set the datastore hostname, but it is not stored in the config
      if role == 'broker' and host_info['roles'].include?('dbserver')
        @env_map['CONF_DATASTORE_HOSTNAME'] = host_info['host']
      end

      # All hosts need to set the named ip address, but only the broker stores it in the config
      if role != 'broker' and host_info['roles'].include?('broker')
        @env_map['CONF_NAMED_IP_ADDR'] = host_info['named_ip_addr']
      end

      if role == 'node' and host_info['roles'].include?('broker')
        @env_map['CONF_BROKER_HOSTNAME'] = host_info['host']
      end
    end
  end

  # Write the openshift.sh settings (safely escaped) to a wrapper script
  filetext = @env_map.map { |env,val| "export #{env}=#{shellescape(val)}\n" }.join ""
  filetext << "rm -f $0\n" unless @keep_assets
  # note: since we are cutting WAY down on output with grep, line-buffer it.
  filetext << "/tmp/openshift.sh |& tee -a #{logfile} | stdbuf -oL -eL grep -i '^OpenShift:'\n"
  filetext << "rm -f /tmp/openshift.sh\n" unless @keep_assets
  filetext << "exit\n"
  # Save it out so we can copy it to the target
  localfile = Tempfile.new('oo-install-wrapper')
  localfile.write(filetext)
  localfile.close

  # Copy the files and run the install
  script_output = ""
  if host['ssh_host'] == 'localhost'
    # relocate launcher file
    system "cp #{File.dirname(__FILE__)}/openshift.sh /tmp/"
    system "chmod u+x #{localfile.path} /tmp/openshift.sh"

    puts "Executing deployment script on localhost (#{host['host']}).\n"
    puts "  You can watch the full log with:\n"
    puts "  #{sudo}tail -f #{logfile}"
    # Run the launcher
    result = @deployment.get_host_instance_by_hostname(host['host']).local_exec!("bash -l -c '#{sudo}#{localfile.path}' 2>&1", true)
    script_output+=result[:stdout]
    result[:success] or return {
      :success => false,
      :recoverable => step != 'configure',
      :message => "Please examine #{logfile} on #{host['ssh_host']} to troubleshoot."
    }
  else
    puts "Copying deployment scripts to target #{host['ssh_host']}.\n"
    bail = Proc.new do |output|
      localfile.delete if localfile.path # ensure it's gone before bailing
      return {
        :success => false,
        :recoverable => true,
        :message => "Could not copy deployment files to remote host:\n#{output}\n"
      }
    end
    # first openshift.sh
    output = `#{@scp_cmd} #{File.dirname(__FILE__)}/openshift.sh #{ssh_path} 2>&1`
    $?.success? or bail.call output
    # then the wrapper script
    output = `#{@scp_cmd} #{localfile.path} #{ssh_path}/#{hostfile} 2>&1`
    $?.success? or bail.call output
    localfile.delete if localfile.path # ensure it's gone before proceeding.
    # now run it
    puts "Executing deployment script on #{host['ssh_host']} (#{host['host']}).\n"
    puts "  You can watch the full log with:\n"
    puts "  #{@ssh_cmd} #{ssh_target} '#{sudo}tail -f #{logfile}'\n"
    result = @deployment.get_host_instance_by_hostname(host['host']).ssh_exec!("#{sudo}chmod u+x /tmp/#{hostfile} /tmp/openshift.sh \&\& #{sudo}/tmp/#{hostfile} 2>&1", true)
    script_output+=result[:stdout]
    result[:exit_code] == 0 or return {
      :success => false,
      # At this point, two ssh commands just succeeded. It's possible, but unlikely
      # that the third one fails before connecting and issuing the command.
      # So, assume that ssh failed in the middle of executing.
      :recoverable => step != 'configure', # which is only a problem for 'configure'
      :message => "Execution of deployment script on remote host failed:\n#{script_output}\n"
    }
  end

  step == 'run_diagnostics'and script_output.match(/FAIL:/) and return {
    :success => false,
    :recoverable => true,
    :message => "Please examine #{logfile} on #{host['ssh_host']} to troubleshoot."
  }

  script_output.gsub("\r",'').split("\n").include?(STEP_SUCCESS_MSG[INSTALL_STEPS.index step]) or return {
    :success => false,
    :recoverable => step != 'configure',
    :message => "Please examine #{logfile} on #{host['ssh_host']} to troubleshoot."
  }

  return {
    :success => true,
    :message => "Step '#{step}' succeeded for host #{host['ssh_host']}\n"
  }
end


##############################################################################


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
  'rh_username' => ['CONF_RHN_USER'],
  'rh_password' => ['CONF_RHN_PASS'],
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

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'broker' => [
    { 'component' => 'broker', 'env_hostname' => 'CONF_BROKER_HOSTNAME', 'env_ip_addr' => 'CONF_BROKER_IP_ADDR',
      'valid_gear_sizes' => 'CONF_VALID_GEAR_SIZES', 'conf_default_districts' => 'CONF_DEFAULT_DISTRICTS',
      'district_mappings' => 'CONF_DISTRICT_MAPPINGS', 'default_gear_size' => 'CONF_DEFAULT_GEAR_SIZE',
      'default_gear_capabilities' => 'CONF_DEFAULT_GEAR_CAPABILITIES',
      'mcollective_user' => 'CONF_MCOLLECTIVE_USER',
      'mcollective_password' => 'CONF_MCOLLECTIVE_PASSWORD',
      'mongodb_broker_user' => 'CONF_MONGODB_BROKER_USER',
      'mongodb_broker_password' => 'CONF_MONGODB_BROKER_PASSWORD',
      'openshift_user' => 'CONF_OPENSHIFT_USER1',
      'openshift_password' => 'CONF_OPENSHIFT_PASSWORD1' },
    { 'component' => 'named', 'env_hostname' => 'CONF_NAMED_HOSTNAME', 'env_ip_addr' => 'CONF_NAMED_IP_ADDR' },
  ],
  'node' => [{ 'component' => 'node', 'env_hostname' => 'CONF_NODE_HOSTNAME',
               'env_ip_addr' => 'CONF_NODE_IP_ADDR', 'node_profile' => 'CONF_NODE_PROFILE',
               'mcollective_user' => 'CONF_MCOLLECTIVE_USER',
               'mcollective_password' => 'CONF_MCOLLECTIVE_PASSWORD' }],
  'msgserver' => [{ 'component' => 'activemq', 'env_hostname' => 'CONF_ACTIVEMQ_HOSTNAME',
                    'mcollective_user' => 'CONF_MCOLLECTIVE_USER',
                    'mcollective_password' => 'CONF_MCOLLECTIVE_PASSWORD' }],
  'dbserver' => [{ 'component' => 'datastore', 'env_hostname' => 'CONF_DATASTORE_HOSTNAME',
                   'mongodb_admin_user' => 'CONF_MONGODB_ADMIN_USER',
                   'mongodb_admin_password' => 'CONF_MONGODB_ADMIN_PASSWORD',
                   'mongodb_broker_user' => 'CONF_MONGODB_BROKER_USER',
                   'mongodb_broker_password' => 'CONF_MONGODB_BROKER_PASSWORD' }],
}

include Installer::Helpers
set_context(:ose)
set_debug(false)
@install_config = Installer::Config.new(@config_file)
@deployment = @install_config.get_deployment

# Will map hosts to roles
@hosts = {}

# Grab the config file contents
@config = YAML.load_file(@config_file)

# Set values from deployment configuration
@seen_roles = {}
if @config.has_key?('Deployment') and @config['Deployment'].has_key?('Hosts') and @config['Deployment'].has_key?('DNS')
  config_hosts = @config['Deployment']['Hosts']
  config_dns = @config['Deployment']['DNS']

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
        # Bail out if this is a node; we'll come back to nodes later.
        break
      end
    end
  end

  # DNS settings
  @env_map['CONF_DOMAIN'] = config_dns['app_domain']
  if 'Y' == config_dns['register_components']
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
COMPONENT_INSTALL_ORDER.each do |order_role|
  next if not order_role == 'node' and not @target_node_ssh_host.nil?
  @hosts.each_pair do |ssh_host,host_info|
    host_info['roles'].each do |host_role|
      @role_map[host_role].each do |ose_info|
        if ose_info['component'] == order_role
          next if @target_node_ssh_host and @target_node_ssh_host != ssh_host
          host_order << host_info unless host_order.include?(host_info)
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
host_order.each do |host|
  puts "  * #{host['ssh_host']}: #{host['roles'].join ', '}\n"
end

# Run the prepare step in parallel
jobs = host_order.select {|host| !state_already? host, 'prepared' }.each do |host|
  fork_and_run(host) do
    run_on_host host, 'prepare'
  end
end
wait_and_report(jobs, 'prepare') # bails if any fail

# Run the install step in parallel
jobs = host_order.select {|host| !state_already? host, 'installed' }.each do |host|
  fork_and_run(host) do
    run_on_host host, 'install'
  end
end
wait_and_report(jobs, 'install') # bails if any fail

# Run the configure step in series
host_order.select {|host| !state_already? host, 'completed' }.each do |host|
  result = run_on_host host, 'configure'
  puts result[:message]
  if result[:success]
    host['state'] = 'completed'
  else
    puts "\n---------------------------------------"
    puts "Install step 'configure' FAILED for:"
    puts "  * #{host['ssh_host']} (#{host['host']})"
    if result[:recoverable]
      puts "It is safe to run this deployment again after problem resolution."
    else
      puts "It is NOT safe to run this deployment again."
      puts "The 'configure' step is unlikely to work correctly after it has failed."
      puts "Sorry; this host probably cannot be recovered."
      host['state'] = 'broken'
    end
    puts "--------------------------------------------"
    save_and_exit 1
  end
end

# Use broker to define DNS entries for new host(s)
if 'Y' == @config['Deployment']['DNS']['register_components']
  @hosts.each do |ssh_host, host|
    next unless host['roles'].include? 'broker'
    result = run_on_host host, 'define_hosts'
    if !result[:success]
      puts "Defining DNS entries for hosts may not have succeeded."
      puts "Please ensure that DNS names for all deployed hosts resolve correctly."
    end
    break
  end
end

# Run post_deploy steps on brokers/nodes
@hosts.each do |ssh_host, host|
  next unless ['completed','validated'].include? host['state']
  next unless host['roles'].include? 'broker'
  result = run_on_host host, 'post_deploy'
  puts result[:message]
  if !result[:success]
    puts "\n---------------------------------------"
    puts "Install step post_deploy FAILED for:"
    puts "  * #{host['ssh_host']} (#{host['host']})"
    puts "--------------------------------------------"
  end
end

@hosts.each do |ssh_host, host|
  next unless host['roles'].include? 'broker' or host['roles'].include? 'node'
  result = run_on_host host, 'run_diagnostics'
  puts result[:message]
  if !result[:success]
    puts "\n---------------------------------------"
    puts "Install step run_diagnostics FAILED for:"
    puts "  * #{host['ssh_host']} (#{host['host']})"
    puts "--------------------------------------------"
  end
end

# total success
puts "All installer steps are complete."
save_and_exit
