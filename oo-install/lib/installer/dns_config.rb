require 'installer/helpers'

module Installer
  class DNSConfig
    include Installer::Helpers

    attr_accessor :app_domain, :component_domain, :register_components

    def initialize dns_config
      @app_domain = dns_config['app_domain'] || 'example.com'
      @component_domain = dns_config['component_domain']
      @register_components = dns_config['register_components']
    end

    def register_components?
      @register_components
    end

    def is_valid?(check=:basic)
      errors = []
      if not is_valid_domain?(app_domain)
        return false if check == :basic
        errors << Installer::DNSConfigDomainInvalidException.new("The application DNS domain value '#{app_domain}' is invalid.")
      end
      if register_components.nil?
        return false if check == :basic
        errors << Installer::DNSConfigMissingSettingException.new("The DNS configuration is missing a value for the 'register_components' setting.")
      end
      if register_components? and component_domain.nil?
        return false if check == :basic
        errors << Installer::DNSConfigDomainMissingException.new("When 'register_components' is set to true, you must provide an OpenShift 'component_domain' value, even if it is identical to the 'app_domain' value.")
      end
      if not component_domain.nil? and not is_valid_domain?(component_domain)
        return false if check == :basic
        errors << Installer::DNSConfigDomainInvalidException.new("The OpenShift component DNS domain value '#{component_domain}' is invalid.")
      end
      return true if check == :basic
      errors
    end

    def to_hash
      output = {
        'app_domain' => app_domain,
        'register_components' => (register_components? ? 'yes' : 'no'),
      }
      if not component_domain.nil?
        output['component_domain'] = component_domain
      end
      output
    end
  end
end
