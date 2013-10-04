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

  class WorkflowFileNotFoundException < Exception
    def initialize(message="The workflow configuration file could not be found at <gem_root>/conf/workflow.cfg", code=1)
      super(message, code)
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

  class WorkflowExecutableException < Exception
    def initialize(message="A workflow executable could not be found or is not system-executable.", code=1)
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

  class HostInstancePortNumberException < Exception
    def initialize(message="A system in the deployment has an invalid port number.", code=1)
      super(message, code)
    end
  end

  class HostInstancePortDuplicateException < Exception
    def initialize(message="A system in the deployment has multiple services listening on the same port.", code=1)
      super(message, code)
    end
  end

  class HostInstanceRoleIncompatibleException < Exception
    def initialize(message="A host instance of one role type was added the host instance list of a different role type.", code=1)
      super(message, code)
    end
  end

  class HostInstanceDuplicateTargetHostException < Exception
    def initialize(message="Multiple host instances in a single role list have the same target host or IP address.", code=1)
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
end
