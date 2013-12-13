require 'i18n'
require 'pathname'
require 'yaml'
require 'installer/version'

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

    def file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end

    def gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
    end

    def supported_contexts
      [:origin, :origin_vm, :ose]
    end

    def supported_targets
      { :fedora => 'Fedora',
        :rhel => 'Red Hat Enterprise Linux',
        :other => 'non-Fedora, non-RHEL',
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

    # SOURCE for #which:
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
            'roles' => ['mqserver','dbserver','broker','node'],
            'status' => 'validated',
          }
        )
        ip_path = which('ip')
        host.set_ip_exec_path(ip_path)
        ip_addrs = host.get_ip_addr_choices
        # For now we blindly assume that the Origin VM will have only one interface
        host.ip_interface = ip_addrs[0][0]
        host.ip_addr = ip_addrs[0][1]
        host
      end
    end

    def sym_to_arg value
      value.to_s.gsub('_','-')
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

    def horizontal_rule
      "----------------------------------------------------------------------"
    end
  end
end
