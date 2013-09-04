require 'highline'

module Installer
  class Question
    attr_reader :workflow, :id, :text, :type

    def initialize workflow, question_config
      @workflow = workflow
      @id = question_config['ID']
      @text = question_config['Text']
      @type = question_config['AnswerType']
    end

    def valid? value
      if type == 'remotehost'

      elsif type == 'mongodbhost'

      elsif type == 'role'

      elsif type == 'rolehost'

      end
    end
  end
end
