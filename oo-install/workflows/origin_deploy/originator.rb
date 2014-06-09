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

###############################################
# Stage 2: Define some locally useful methods #
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

#############################################
# Stage 3: Load and check the configuration #
#############################################

set_context(:origin)

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
    puts "  * #{error}"
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

############################################
# Stage 4: Workflow-specific configuration #
############################################

# See if the Node to add exists in the config
host_installation_order = []
if not @target_node_hostname.nil?
  deployment.get_hosts_by_role(:node).select{ |h| h.roles.count == 1 and h.host == @target_node_hostname }.each do |host_instance|
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

# Default and baked-in config values for the Puppet deployment
@puppet_map = {
  'roles' => ['broker','activemq','datastore','named'],
  'jenkins_repo_base' => 'http://pkg.jenkins-ci.org/redhat',
}

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
@env_input_map.each_pair do |env_var,puppet_var|
  env_key = "OO_INSTALL_#{env_var.upcase}"
  if ENV.has_key?(env_key)
    @puppet_map[puppet_var] = ENV[env_key]
  end
end

# Possible HA Broker Configuration
if deployment.brokers.length > 1
  cluster_members  = []
  cluster_ip_addrs = []

  @puppet_map['broker_cluster_members'] = "[#{deployment.brokers.
end

@utility_install_order = ['nameserver','datastore','msgserver','broker','node']

# Set the installation order (if the Add a Node workflow didn't already set it)
if host_installation_order.length == 0
  @utility_install_order.map{ |r| r.to_sym }.each do |order_role|
    deployment.get_hosts_by_role(order_role).each do |host_instance|
      next if host_order.include?(host_instance.host)
      host_order << host_instance
    end
  end
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

  logfile = "/tmp/openshift-deploy.log"

  # Set up the commands that we will be using.
  commands = {
    :typecheck => "export LC_CTYPE=en_US.utf8 && cat /etc/redhat-release",
    :keycheck => "ls /var/named/K#{@puppet_map['domain']}*.key",
    :hosts_keycheck => "ls /var/named/K#{@puppet_map['hosts_domain']}*.key",
    :keygen => "dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{@puppet_map['domain']}",
    :hosts_keygen => "dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom -K /var/named #{@puppet_map['hosts_domain']}",
    :keyget => "cat /var/named/K#{@puppet_map['domain']}*.key",
    :hosts_keyget => "cat /var/named/K#{@puppet_map['hosts_domain']}*.key",
    :enabledns => 'systemctl enable named.service',
    :enabledns_rhel => 'service named restart',
    :uninstall => "puppet module uninstall -f #{@puppet_module_name}",
    :install => "puppet module install -v #{@puppet_module_ver} #{@puppet_module_name}",
    :yum_clean => 'yum clean all',
    :apply => "puppet apply --verbose /tmp/#{hostfile} |& tee -a #{logfile}",
    :clear => "rm /tmp/#{hostfile}",
  }
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
      if not user == 'root'
        commands[action] = "sudo sh -c '#{commands[action]}'"
      end
      commands[action] = "#{@ssh_cmd} #{user}@#{ssh_host} -C \"#{commands[action]}\""
    else
      commands[action] = "bash -l -c '#{commands[action]}'"
      if not user == 'root'
        commands[action] = "sudo #{commands[action]}"
      end
    end
    if action == :typecheck
      output = `#{commands[:typecheck]} 2>&1`
      if not output.chomp.strip.downcase.start_with?('fedora')
        host_type = :other
      end
    end
  end

  # Figure out the DNS key(s) before we write the puppet config file
  if @hosts[ssh_host]['roles'].include?('broker')
    dns_jobs = [
      { :check => commands[:keycheck],
        :domain => @puppet_map['domain'],
        :generate => commands[:keygen],
        :get => commands[:keyget],
        :cfg_key => 'bind_key'
      }
    ]
    if not @puppet_map['hosts_domain'].nil? and not @puppet_map['hosts_domain'].empty?
      dns_jobs << {
        :check => commands[:hosts_keycheck],
        :domain => @puppet_map['hosts_domain'],
        :generate => commands[:hosts_keygen],
        :get => commands[:hosts_keyget],
        :cfg_key => 'hosts_bind_key'
      }
    end

    dns_jobs.each do |dns_job|
      puts "\nChecking for #{dns_job[:domain]} DNS key(s) on #{ssh_host}..."
      output = `#{dns_job[:check]} 2>&1`
      chkstatus = $?.exitstatus
      if chkstatus > 0
        # No key; build one.
        puts "...none found; attempting to generate one.\n"
        output = `#{dns_job[:generate]} 2>&1`
        genstatus = $?.exitstatus
        if genstatus > 0
          puts "Could not generate a DNS key. Exiting."
          saw_deployment_error = true
          break
        end
        puts "Key generation successful."
      else
        puts "...found at /var/named/K#{dns_job[:domain]}*.key\n"
      end

      # Copy the public key info to the config file.
      key_text = `#{dns_job[:get]} 2>&1`
      getstatus = $?.exitstatus
      if getstatus > 0 or key_text.nil? or key_text == ''
        puts "Could not read DNS key data from /var/named/K#{dns_job[:domain]}*.key. Exiting."
        saw_deployment_error = true
        break
      end

      # Format the public key correctly.
      key_vals = key_text.strip.split(' ')
      @puppet_map[dns_job[:cfg_key]] = "#{key_vals[6]}#{key_vals[7]}"
    end

    # Bail out if we hit problems with DNS key gen.
    break if saw_deployment_error

    # Finally, make sure the named service is enabled.
    output = `#{commands[:enabledns]} 2>&1`
    dnsstatus = $?.exitstatus
    if dnsstatus > 0
      # This may be RHEL (or at least, not systemd)
      puts "Command 'systemctl' didn't work; trying older style..."
      output = `#{commands[:enabledns_rhel]} 2>&1`
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
