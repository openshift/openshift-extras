module Installer
  class Exception < StandardError
    attr_reader :code
    def initialize(message=nil, code=1)
      super(message)
      @code = code
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
end
