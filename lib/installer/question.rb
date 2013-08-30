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

    def run config
      previous_answer = config.get_question_value(workflow.id, id)
      response = previous_answer ? ask(text, type){ |q| q.default = previous_answer } : ask(text, type)
      config.set_question_value(workflow.id, id, response)
    end
  end
end
