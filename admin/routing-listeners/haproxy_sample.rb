#!/usr/bin/ruby

# Haproxy sample routing listener

# Haproxy configuration file join code originally from https://github.com/joewilliams/haproxy_join
# This listener assumes haproxy configuration has been divided into the following directory structure:
# CONF_DIR/conf/global.cfg
# CONF_DIR/conf/defaults.cfg
# CONF_DIR/conf/frontend.cfg
# CONF_DIR/conf/frontend.d/
# CONF_DIR/conf/backend.d/

require 'rubygems'
require 'stomp'
require 'yaml'
require 'find'
begin
  require 'ftools'
rescue LoadError
  # Not on a 1.8 vm. Try 1.9 fileutils
  require 'fileutils'
end

CONF_DIR='/etc/haproxy'
DOMAIN='example.com'

# Add an haproxy head gear to the configuration
def add_haproxy(appname, namespace, ip, port)
  scope = "#{appname}-#{namespace}"
  frontend_file = File.join(CONF_DIR, "conf/frontend.d/#{scope}.cfg")
  backend_file = File.join(CONF_DIR, "conf/backend.d/#{scope}.cfg")

  backend_name = scope + "_backend"

  if not File.exist?(frontend_file)
    puts "Creating new frontend for #{scope}"
    template = <<-EOF
acl #{scope} hdr(host) -i ha-#{scope}.#{DOMAIN}
use_backend #{backend_name} if #{scope}
EOF
    File.open(frontend_file, 'w') { |f| f.write(template) }
  end

  if File.exist?(backend_file)
    # If the cfg file already exists, update it
    puts "Adding endpoint #{ip}:#{port} for #{scope}"
    File.open(backend_file, 'a') do |f|
      f.write("  server #{scope}.#{DOMAIN} #{ip}:#{port} check port 80\n")
    end
  else
    puts "Creating new backend for #{scope} with endpoint #{ip}:#{port}"
    template = <<-EOF
backend #{backend_name}
  balance     roundrobin
  option httpchk /health
  http-send-name-header Host
  server #{scope}.#{DOMAIN} #{ip}:#{port} check port 80
EOF
    File.open(backend_file, 'w') { |f| f.write(template) }
  end

  restart_haproxy
end

# Remove an haproxy head gear from the configuration
def remove_haproxy(scope)
  frontend_file = File.join(CONF_DIR, "conf/frontend.d/#{scope}.cfg")
  backend_file = File.join(CONF_DIR, "conf/backend.d/#{scope}.cfg")
  restart_needed = false
  if File.exist?(frontend_file)
    File.delete(frontend_file)
    restart_needed = true
    puts "Removed frontend for #{scope}"
  end
  if File.exist?(backend_file)
    File.delete(backend_file)
    restart_needed = true
    puts "Removed backend for #{scope}"
  end
  restart_haproxy if restart_needed
end

def restart_haproxy
  puts "Joining configuration files and restarting haproxy."
  join_haproxy_config("haproxy.cfg", CONF_DIR)
  `service haproxy restart`
end

# Join all haproxy configuration files
def join_haproxy_config(haproxy_filename, haproxy_dir)
  main_config = File.join(haproxy_dir, haproxy_filename)

  if File.exist?(main_config)
    begin
      File.copy(main_config, main_config + ".BAK-" + Time.now.strftime("%Y%m%d%H%M%S"))
    rescue NoMethodError
      FileUtils.cp(main_config, main_config + ".BAK-" + Time.now.strftime("%Y%m%d%H%M%S"))
    end
  end

  @haproxy_config = File.new(main_config, "w")

  global = File.new(File.join(haproxy_dir, "conf", "global.cfg"), "r")
  defaults = File.new(File.join(haproxy_dir, "conf", "defaults.cfg"), "r")
  frontend = File.new(File.join(haproxy_dir, "conf", "frontend.cfg"), "r")

  @haproxy_config.write(global.read)
  @haproxy_config.write(defaults.read)
  @haproxy_config.write(frontend.read)

  global.close
  defaults.close
  frontend.close

  join_haproxy_dir(File.join(haproxy_dir, "conf", "frontend.d"))
  join_haproxy_dir(File.join(haproxy_dir, "conf", "backend.d"))
  @haproxy_config.close
end

# Write frontend and backend haproxy configuration directories
def join_haproxy_dir(config_d)
  config_files = []

  # use .cfg as file extension for all configs
  extension = ".cfg"

  Find.find(config_d) do |file|
    if extension.include?(File.extname(file))
      config_files << file
    end
  end

  config_files.each do |file|
    @haproxy_config.write(File.new(File.join(file), "r").read)
  end
end

c = Stomp::Client.new("routinginfo", "routingpassword", "localhost", 61613, true)
c.subscribe('/topic/routinginfo') { |msg|
  h = YAML.load(msg.body)
  if h[:action] == :add_public_endpoint 
    if h[:types].include? "load_balancer"
      add_haproxy(h[:app_name], h[:namespace], h[:public_address], h[:public_port])
    end
  elsif h[:action] == :remove_public_endpoint
  # script does not actually act upon the remove_public_endpoint as written
  elsif h[:action] == :delete_application
    scope = "#{h[:app_name]}-#{h[:namespace]}"
    remove_haproxy(scope)
  end
}
c.join
