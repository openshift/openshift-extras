require 'i18n'
require 'pathname'
require 'yaml'

module Installer
  module Helpers
    include I18n

    VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')
    VALID_HOSTNAME_RE = Regexp.new('^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$')
    VALID_USERNAME_RE = Regexp.new('^[a-z][-a-z0-9]*$')

    def file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end

    def gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
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

    def is_valid_hostname_or_ip_addr? text
      text.match VALID_IP_ADDR_RE or text.match VALID_HOSTNAME_RE
    end

    def is_valid_remotehost? text
      user = text.split('@')[0]
      hostport = text.split('@')[1]
      host = hostport.split(':')[0]
      port = hostport.split(':')[1]
      is_valid_username?(user) and is_valid_hostname_or_ip_addr?(host) and (port.nil? or is_valid_port_number?(port))
    end

    def is_valid_mongodbhost? text
      hostportlist = []
      if text.include?('@')
        user = text.split('@')[0].split(':')[0]
        return false if not is_valid_username?(user)
        pass = text.split('@')[0].split(':')[1]
        hostportlist = text.split('@')[1].split(',')
      else
        hostportlist = text.split(',')
      end
      hostportlist.each do |hostport|
        host = hostport.split(':')[0]
        return false if not is_valid_hostname_or_ip_addr?(host)
        port = hostport.split(':')[1]
        return false if not port.nil? and not is_valid_port_number?(port)
      end
      true
    end

    def is_valid_port_number? text
      text.to_i > 0 and text.to_i <= 65535
    end

    def is_valid_username? text
      text.match VALID_USERNAME_RE
    end

    def is_valid_role_list? text
      text.split(',').each do |item|
        if not item.strip == 'all' and not Installer::Deployment.roles.include?(item.strip)
          return false
        end
      end
      true
    end
  end
end

