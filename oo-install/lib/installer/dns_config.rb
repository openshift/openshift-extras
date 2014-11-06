require 'installer/helpers'

module Installer
  class DNSConfig
    include Installer::Helpers

    attr_accessor :app_domain, :component_domain, :register_components, :deploy_dns, :dns_host_name, :dns_host_ip, :dnssec_key

    def initialize dns_config
      @app_domain = dns_config['app_domain'] || 'example.com'
      @component_domain = dns_config['component_domain']
      @register_components = dns_config.has_key?('register_components') && dns_config['register_components'].downcase == 'y'
      @deploy_dns = (not dns_config.has_key?('deploy_dns') or dns_config['deploy_dns'].downcase == 'y')
      @dns_host_name = dns_config['dns_host_name']
      @dns_host_ip = dns_config['dns_host_ip']
      @dnssec_key = dns_config['dnssec_key']
    end

    def register_components?
      @register_components
    end

    def deploy_dns?
      @deploy_dns
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
      if deploy_dns.nil?
        return false if check == :basic
        errors << Installer::DNSConfigMissingSettingException.new("The DNS configuration is missing a value for the 'deploy_dns' setting.")
      end
      if not deploy_dns
        if dns_host_name.nil? or dns_host_ip.nil? or dnssec_key.nil?
          return false if check == :basic
          errors << Installer::DNSConfigMissingSettingException.new("When OpenShift is not deploying its own DNS service, you must provide the name and IP address of an existing DNS server, along with a 'dnssec_key' value so that Nodes can register user applications with your DNS system.")
        end
        if not is_valid_ip_addr?(dns_host_ip)
          return false if check == :basic
          errors << Installer::HostInstanceIPAddressException.new("IP address '#{dns_host_ip}' for the externally hosted DNS service is invalid.")
        end
        if not is_valid_hostname?(dns_host_name) or dns_host_name == 'localhost'
          return false if check == :basic
          errors << Installer::HostInstanceHostNameException.new("DNS server host name '#{dns_host_name}' is invalid. Note that 'localhost' is not a permitted value here.")
        end
        if not is_valid_string?(dnssec_key)
          return false if check == :basic
          errors << Installer::DNSConfigMissingSettingException.new("A DNSSEC key value must be provided for the externally hosted DNS server.")
        end
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
        'register_components' => (register_components? ? 'Y' : 'N'),
        'deploy_dns' => (deploy_dns? ? 'Y' : 'N'),
      }
      if not component_domain.nil?
        output['component_domain'] = component_domain
      end
      if not deploy_dns?
        output['dns_host_name'] = dns_host_name
        output['dns_host_ip']   = dns_host_ip
      end
      output['dnssec_key'] = dnssec_key unless dnssec_key.nil?
      output
    end
  end
end
