require 'rspec'
require 'simplecov'

SimpleCov.start

require 'installer/helpers'

module SpecHelpers
  include Installer::Helpers

  def test_workflows
    [
      { 'ID' => 'test1',
        'Name' => 'Test Workflow 1',
        'Description' => 'Description for test workflow 1',
        'Executable' => "echo 'test 1'",
      },
      { 'ID' => 'test2',
        'Name' => 'Test Workflow 2',
        'Description' => 'Description for test workflow 2',
        'SkipDeploymentCheck' => 'Y',
        'Executable' => "echo 'test2'",
        'Questions' =>
        [
          { 'Text' => 'Question 1',
            'Variable' => 'question1',
            'AnswerType' => ['Y','N'],
          },
        ],
      }
    ]
  end
end

RSpec::Matchers.define :have_same_hash_contents_as do |expected|
  match do |actual|
    (actual.keys.length == expected.keys.length) &&
    (actual.keys.map{ |k| k.to_s }.sort.join('::') == expected.keys.map{ |k| k.to_s }.sort.join('::')) &&
    (actual.values.map{ |v| v.to_s }.sort.join('::') == expected.values.map{ |v| v.to_s }.sort.join('::'))
  end
end

RSpec.configure do |config|
  config.include(SpecHelpers)
end
