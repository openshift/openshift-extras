module Installer
  class Exception < StandardError
    attr_reader :code
    def initialize(message=nil, code=1)
      super(message)
      @code = code
    end
  end

  class AssistantRestartException < Exception
    def initialize(message="The user has requested to quit out to the main menu.", code=1)
      super(message, code)
    end
  end

  class AssistantWorkflowCompletedException < Exception
    def initialize(message="The selected installation workflow has completed.", code=1)
      super(message, code)
    end
  end

  class AssistantWorkflowNonDeploymentCompletedException < Exception
    def initialize(message="The selected non-deployment installation workflow has completed.", code=1)
      super(message, code)
    end
  end

  class AssistantMissingUtilityException < Exception
    def initialize(message="A utility program used by oo-install could not be found.", code=1)
      super(message,code)
    end
  end

  class FileNotFoundException < Exception
    def initialize(description="", file_path="", code=1)
      super("The #{description} configuration file could not be found at #{file_path}", code)
    end
  end

  class WorkflowNotFoundException < Exception
    def initialize(message="A workflow with the provided ID could not be found.", code=1)
      super(message, code)
    end
  end

  class WorkflowMissingRequiredSettingException < Exception
    def initialize(message="A workflow is missing a required configuration setting.", code=1)
      super(message, code)
    end
  end

  class WorkflowQuestionReservedVariableException < Exception
    def initialize(message="A workflow question is using a reserved variable name.", code=1)
      super(message, code)
    end
  end

  class WorkflowConfigValueException < Exception
    def initialize(message="A workflow configuration value is not valid.", code=1)
      super(message, code)
    end
  end

  class WorkflowConfigurationIncompleteException < Exception
    def initialize(message="The workflow configuration is missing one or more settings.", code=1)
      super(message, code)
    end
  end

  class WorkflowExecutableException < Exception
    def initialize(message="A workflow executable could not be found or is not system-executable.", code=1)
      super(message, code)
    end
  end

  class WorkflowContextNotRecognizedException < Exception
    def intialize(message="A workflow 'Contexts' value was not recognized.", code=1)
      super(message, code)
    end
  end

  class WorkflowTargetNotRecognizedException < Exception
    def intialize(message="A workflow 'Targets' value was not recognized.", code=1)
      super(message, code)
    end
  end

  class DeploymentHAMisconfiguredException < Exception
    def initialize(message="The HA configuration check was not successful. See above for specific issues.", code=1)
      super(message, code)
    end
  end

  class DeploymentCheckFailedException < Exception
    def initialize(message="The deployment check was not successful. See above for specific issues.", code=1)
      super(message, code)
    end
  end

  class DeploymentRoleMissingException < Exception
    def initialize(message="One of the deployment roles has not been assigned to any host instance.", code=1)
      super(message, code)
    end
  end

  class DeploymentAccountInfoMismatchException < Exception
    def initialize(message="The username/password combo for a particular service does not match across host instances.", code=1)
      super(message, code)
    end
  end

  class DNSConfigDomainInvalidException < Exception
    def initialize(message="One of the domains specified in the DNS configuration is invalid.", code=1)
      super(message, code)
    end
  end

  class DNSConfigDomainMissingException < Exception
    def initialize(message="A required DNS domain value is missing from the DNS configuration.", code=1)
      super(message, code)
    end
  end

  class DNSConfigMissingSettingException < Exception
    def initialize(message="A required setting is missing from the DNS configuration.", code=1)
      super(message, code)
    end
  end

  class SSHNotAvailableException < Exception
    def initialize(message="An ssh client could not be found on this system. Correct this and rerun the installer.", code=1)
      super(message, code)
    end
  end

  class HostInstanceUtilityNotAvailableException < Exception
    def initialize(message="The 'yum' utility could not be found on the target system.", code=1)
      super(message, code)
    end
  end

  class HostInstanceNotReachableException < Exception
    def initialize(message="A target host in the deployment could not be reached.", code=1)
      super(message, code)
    end
  end

  class HostInstanceHostNameException < Exception
    def initialize(message="A system in the deployment has an invalid hostname or IP address.", code=1)
      super(message, code)
    end
  end

  class HostInstanceUserNameException < Exception
    def initialize(message="A system in the deployment has an invalid user name.", code=1)
      super(message, code)
    end
  end

  class HostInstanceIPAddressException < Exception
    def initialize(message="A system in the deployment has an invalid IP address.", code=1)
      super(message, code)
    end
  end

  class HostInstanceIPInterfaceException < Exception
    def initialize(message="A system in the deployment is missing an IP interface value.", code=1)
      super(message, code)
    end
  end

  class HostInstanceDuplicateRoleException < Exception
    def initialize(message="A host instance has been assigned to the same role multiple times.", code=1)
      super(message, code)
    end
  end

  class HostInstanceMismatchedSettingsException < Exception
    def initialize(message="A host instance has conflicting settings.", code=1)
      super(message, code)
    end
  end

  class HostInstanceSettingException < Exception
    def initialize(message="A host instance has a missing or malformed setting value.", code=1)
      super(message, code)
    end
  end

  class BrokerGlobalSettingsException < Exception
    def intialize(message="One of the Broker global settings is incorrect.")
      super(message, code)
    end
  end

  class DistrictSettingsException < Exception
    def intialize(message="One of the District configuration settings is incorrect.")
      super(message, code)
    end
  end

  class HostInstanceUnassignedException < Exception
    def initialize(message="A host instance is not configured to any OpenShift roles.", code=1)
      super(message, code)
    end
  end

  class SubscriptionTypeNotRecognizedException < Exception
    def initialize(message="The specified subscription type is not recognized by the installer.", code=1)
      super(message, code)
    end
  end

  class InvalidSubscriptionSettingException < Exception
    def initialize(message="The subscription config contains invalid settings for the subscription type.", code=1)
      super(message, code)
    end
  end

  class SubscriptionSettingNotValidException < Exception
    def initialize(message="The subscription config contains an invlid setting value.", code=1)
      super(message, code)
    end
  end

  class SubscriptionSettingMissingException < Exception
    def initialize(message="The subscription config is missing a required setting for the specified config type.", code=1)
      super(message, code)
    end
  end

  class UnrecognizedContextException < Exception
    def initialize(message="The provided installer context is not supported.", code=1)
      super(message, code)
    end
  end
end
