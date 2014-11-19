require 'i18n'
require 'pathname'
require 'yaml'
require 'installer/exceptions'
require 'installer/version'
require 'securerandom'
require 'openssl'

module Installer
  module Helpers
    include I18n

    VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')
    VALID_HOSTNAME_RE = Regexp.new('^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$')
    VALID_USERNAME_RE = Regexp.new('^[a-z][-a-z0-9]*$')
    VALID_DOMAIN_RE = Regexp.new('^[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,63}$')
    VALID_URL_RE = Regexp.new('^https?:\/\/[\da-z\.-]+:?\d*\/[\w~\/-]*\/?')
    VALID_EMAIL_RE = Regexp.new('@')
    BLANK_STRING_RE = Regexp.new('^\s*$')
    ADMIN_PATHS = '/sbin:/usr/sbin'

    def file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end

    def parse_config_file(description, file_path)
      unless File.exists?(file_path)
        raise Installer::FileNotFoundException.new(description, file_path)
      end
      yaml = YAML.load_stream(open(file_path))
      if yaml.is_a?(Array)
        # Ruby 1.9.3+
        return yaml
      else
        # Ruby 1.8.7
        return yaml.documents
      end
    end

    def gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
    end

    def supported_contexts
      [:origin, :origin_vm, :ose]
    end

    def supported_targets
      { :rhel   => 'Red Hat Enterprise Linux',
        :centos => 'CentOS',
      }
    end

    def set_context(context)
      if not supported_contexts.include?(context)
        raise UnrecognizedContextException.new("Installer context #{context} not recognized.\nLegal values are #{supported_contexts.join(', ')}.")
      end
      Installer.const_set("CONTEXT", context)
    end

    def get_context
      Installer::CONTEXT
    end

    def set_mode(advanced_mode)
      Installer.const_set("ADVANCED", advanced_mode)
    end

    def advanced_mode?
      Installer::ADVANCED
    end

    def set_debug(debug)
      Installer.const_set("DEBUG", debug)
    end

    def is_origin_vm?
      get_context == :origin_vm
    end

    def debug_mode?
      Installer::DEBUG
    end

    def set_keep_puppet(keep_puppet)
      Installer.const_set("KEEP_PUPPET", keep_puppet)
    end

    def keep_puppet?
      Installer::KEEP_PUPPET
    end

    def set_advanced_repo_config(advanced_repo_config)
      Installer.const_set("ADVANCED_REPO_CONFIG", advanced_repo_config)
    end

    def advanced_repo_config?
      Installer::ADVANCED_REPO_CONFIG
    end

    def set_force_install(force_install)
      Installer.const_set("FORCE_INSTALL", force_install)
    end

    def force_install?
      Installer::FORCE_INSTALL
    end

    # SOURCE for #which:
    # http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      paths = ENV['PATH'].split(File::PATH_SEPARATOR)
      ADMIN_PATHS.split(':').each do |admin_path|
        paths << admin_path unless paths.include? admin_path
      end
      paths.each do |path|
        exts.each { |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable? exe
        }
      end
      return nil
    end

    def wrap_long_string(text,max_width = 70)
      text.gsub(/(.{1,#{max_width}})(?: +|$)\n?|(.{#{max_width}})/, "\\1\\2\n")
    end

    def i18n_configured?
      @i18n_configured ||= false
    end

    def translate text
      unless i18n_configured?
        I18n.load_path += Dir[gem_root_dir + '/config/locales/*.yml']
        @i18n_configured = true
      end
      I18n.t text
    end

    def vm_installer_host
      @vm_installer_host ||= begin
        host = Installer::HostInstance.new(
          { 'host' => `hostname`.chomp.strip,
            'ssh_host' => 'localhost',
            'user' => 'root',
            'roles' => ['msgserver','dbserver','broker','node','nameserver'],
            'status' => 'validated',
          }
        )
        ip_path = which('ip')
        host.set_ip_exec_path(ip_path)
        ip_addrs = host.get_ip_addr_choices
        # For now we blindly assume that the Origin VM will have only one interface
        if not ip_addrs.empty?
          host.ip_interface = ip_addrs[0][0]
          host.ip_addr = ip_addrs[0][1]
        end
        host
      end
    end

    def sym_to_arg value
      value.to_s.gsub('_','-')
    end

    def ha_service_accounts_info
      { :mongodb_replica_key => {
          :name  => 'MongoDB Replica Key',
          :question => "\nWhat replica key value should the DB servers use? ",
          :order => 11,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:dbserver],
        },
        :mongodb_replica_name => {
          :name  => 'MongoDB Replica Set Name',
          :question => "\nWhat replica set name should the DB servers use? ",
          :order => 10,
          :value => 'openshift',
          :roles => [:dbserver],
        },
        :msgserver_cluster_password => {
          :name  => 'MsgServer Cluster Password',
          :question => "\nWhat password should the MsgServer cluster use for inter-cluster communication? ",
          :order => 20,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:msgserver],
        },
      }
    end

    def service_accounts_info
      { :mcollective_user => {
          :name  => 'MCollective User',
          :order => 30,
          :value => 'mcollective',
          :roles => [:broker, :node, :msgserver],
          :description =>
            'This is the username shared between broker and node
             for communicating over the mcollective topic
             channels in ActiveMQ. Must be the same on all
             broker and node hosts.'.gsub(/( |\t|\n)+/, " ")
        },
        :mcollective_password => {
          :name  => 'MCollective Password',
          :order => 31,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker, :node, :msgserver],
          :description =>
            'This is the password shared between broker and node
             for communicating over the mcollective topic
             channels in ActiveMQ. Must be the same on all
             broker and node hosts.'.gsub(/( |\t|\n)+/, " ")
        },
        :mongodb_broker_user => {
          :name  => 'MongoDB Broker User',
          :order => 42,
          :value => 'openshift',
          :roles => [:broker, :dbserver],
          :description =>
            'This is the username that will be created for the
             broker to connect to the MongoDB datastore. Must
             be the same on all broker and datastore
             hosts'.gsub(/( |\t|\n)+/, " ")
        },
        :mongodb_broker_password => {
          :name  => 'MongoDB Broker Password',
          :order => 43,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker, :dbserver],
          :description =>
            'This is the password that will be created for the
             broker to connect to the MongoDB datastore. Must
             be the same on all broker and datastore
             hosts'.gsub(/( |\t|\n)+/, " ")
        },
        :mongodb_admin_user => {
          :name  => 'MongoDB Admin User',
          :order => 40,
          :value => 'admin',
          :roles => [:dbserver],
          :description =>
            'This is the username of the administrative user
             that will be created in the MongoDB datastore.
             These credentials are not used by OpenShift, but
             an administrative user must be added to MongoDB
             in order for it to enforce
             authentication.'.gsub(/( |\t|\n)+/, " ")
        },
        :mongodb_admin_password => {
          :name  => 'MongoDB Admin Password',
          :order => 41,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:dbserver],
          :description =>
            'This is the password of the administrative user
             that will be created in the MongoDB datastore.
             These credentials are not used by OpenShift, but
             an administrative user must be added to MongoDB
             in order for it to enforce
             authentication.'.gsub(/( |\t|\n)+/, " ")
        },
        :openshift_user => {
          :name  => 'OpenShift Console User',
          :order => 1,
          :value => 'demo',
          :roles => [:broker],
          :description =>
            'This is the username created in
             /etc/openshift/htpasswd and used by the
             openshift-origin-auth-remote-user-basic
             authentication plugin.'.gsub(/( |\t|\n)+/, " ")
        },
        :openshift_password => {
          :name  => 'OpenShift Console Password',
          :order => 2,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker],
          :description =>
            'This is the password created in
             /etc/openshift/htpasswd and used by the
             openshift-origin-auth-remote-user-basic
             authentication plugin.'.gsub(/( |\t|\n)+/, " ")
        },
        :broker_session_secret => {
          :name  => 'Broker Session Secret',
          :order => 10,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker],
          :description =>
            'This is the session secret used by the broker rest api'
        },
        :console_session_secret => {
          :name  => 'Console Session Secret',
          :order => 11,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker],
          :description =>
            'This is the session secret used by the web console'
        },
        :broker_auth_salt => {
          :name  => 'Broker Auth Salt',
          :order => 12,
          :value => SecureRandom.base64.delete('+/='),
          :roles => [:broker],
          :description =>
            'This is the authentication salt used by the broker'
        },
        :broker_auth_priv_key => {
          :name  => 'Broker Auth Private Key',
          :order => 13,
          :value => OpenSSL::PKey::RSA.new(2048).to_pem,
          :roles => [:broker],
          :description =>
            'This is the RSA Private Key used for broker access by remote applications (i.e. Jenkins)'
        },
      }
    end

    def is_valid_ip_addr? text
      not text.nil? and text.match VALID_IP_ADDR_RE
    end

    def is_valid_hostname? text
      not text.nil? and text.match VALID_HOSTNAME_RE
    end

    def is_valid_hostname_or_ip_addr? text
      not text.nil? and (is_valid_ip_addr?(text) or is_valid_hostname?(text))
    end

    def is_valid_domain? text
      not text.nil? and text.match VALID_DOMAIN_RE
    end

    def is_valid_url? text
      not text.nil? and text.match VALID_URL_RE
    end

    def is_valid_remotehost? text
      return false if text.nil?
      user = text.split('@')[0]
      hostport = text.split('@')[1]
      host = hostport.split(':')[0]
      port = hostport.split(':')[1]
      is_valid_username?(user) and is_valid_hostname_or_ip_addr?(host) and (port.nil? or is_valid_port_number?(port))
    end

    def is_valid_username? text
      not text.nil? and text.match VALID_USERNAME_RE
    end

    def is_valid_email_addr? text
      not text.nil? and text.match VALID_EMAIL_RE
    end

    def is_valid_string? text
      return false if text.nil? or text.empty? or text.match BLANK_STRING_RE
      true
    end

    def is_valid_role_list? text
      return false if text.nil?
      text.split(',').each do |item|
        if not item.strip == 'all' and not Installer::Deployment.roles.include?(item.strip)
          return false
        end
      end
      true
    end

    def installer_version_gte?(config_version)
      inst_version = Installer::VERSION.split('.')
      cfg_version = config_version.split('.')
      for i in 0..9
        inst_num = inst_version[i]
        cfg_num = cfg_version[i]
        if cfg_num.nil?
          # Comparison over; installer is more recent
          return true
        elsif inst_num.nil? or (cfg_num.to_i > inst_num.to_i)
          # Comparison over; config file is more recent
          return false
        end
      end
    end

    # The output of the rhsm repo listing is of the multi-line format:
    #
    # Repo ID:   <repo_id>
    # Repo Name: <repo_name>
    # Repo URL:  <repo_url>
    # Enabled:   <0|1>
    #
    # This helper matched repos by repo ID substring and correlates the
    # ID to the 'enabled' flag reported in the same block.
    def rhsm_enabled_repo?(rhsm_text, repo_substr)
      in_repo_block = false
      rhsm_text.split("\n").each do |line|
        if not in_repo_block
          if line =~ /^Repo ID/ and line =~ /#{repo_substr}/
            in_repo_block = true
          end
          next
        else
          if line =~ /^\s*$/
            in_repo_block = false
          elsif line =~ /^Enabled/
            if line =~ /1/
              return true
            end
          end
        end
      end
      return false
    end

    def get_domain_from_fqdn(fqdn)
      fqdn.split('.').drop(1).join('.')
    end

    def capitalize_attribute(attr)
      attr.to_s.split('_').map{ |word|
        case word
        when 'mongodb' then 'MongoDB'
        when 'openshift' then 'OpenShift'
        when 'mcollective' then 'MCollective'
        when 'db','ssh','ip' then word.upcase
        else word.capitalize
        end }.join(' ')
    end

    def horizontal_rule
      "----------------------------------------------------------------------"
    end
  end
end
