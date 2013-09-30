require 'spec_helper'
require 'installer/workflow'
require 'installer/executable'
require 'installer/question'

describe Installer::Workflow do
  context 'without a workflow config file' do
    before{ Installer::Workflow.stub(:file_path).and_return('/foo/bar/baz') }
    subject{ Installer::Workflow.ids }
    it "should raise a 'file not found' error" do
      expect { subject }.to raise_error(Installer::WorkflowFileNotFoundException)
    end
  end

  context 'with an incorrect config file' do
    before { Installer::Workflow.stub(:parse_config_file).and_return([{ 'Foo' => 'Bar' },{ 'Foo' => 'Baz' }]) }
    subject { Installer::Workflow.ids }
    it "should raise a 'missing required settings' error" do
      expect { subject }.to raise_error(Installer::WorkflowMissingRequiredSettingException)
    end
  end

  context 'with a valid configuration' do
    before :each do
      Installer::Workflow.stub(:parse_config_file).and_return(test_workflows)
    end
    it 'should list the workflow ids' do
      Installer::Workflow.ids.should =~ test_workflows.map{ |w| w['ID'] }
    end
    it 'should list the workflow ids and descriptions' do
      subject_list =  Installer::Workflow.list
      test_list = test_workflows.map{ |w| { :id => w['ID'], :desc => w['Description'] } }
      subject_list.length.should equal(test_list.length)
      for i in 0..(test_list.length - 1)
        subject_list[i].should have_same_hash_contents_as test_list[i]
      end
    end
    it 'should raise an error when an undefined worflow is requested' do
      expect { Installer::Workflow.find('foobar') }.to raise_error(Installer::WorkflowNotFoundException)
    end
    it 'should instantiate a valid requested workflow' do
      Installer::Workflow.ids.each do |id|
        test_item = test_workflows.find{ |w| w['ID'] == id }
        workflow = Installer::Workflow.find(id)
        workflow.id.should equal(id)
        workflow.name.should == test_item['Name']
        workflow.description.should == test_item['Description']
        workflow.executable.should be_kind_of(Installer::Executable)
        workflow.path.should == gem_root_dir + '/workflows/' + id
        workflow.questions.each do |question|
          question.should be_kind_of(Installer::Question)
        end
      end
    end
    it 'should provide a default value for optional settings' do
      test_yaml = test_workflows.find{ |w| w['ID'] == 'test1' }
      test_yaml.has_key?('SkipDeploymentCheck').should be_false
      test_yaml.has_key?('ExecuteOnTarget').should be_false
      subject_obj = Installer::Workflow.find('test1')
      subject_obj.check_deployment?.should be_true
      subject_obj.remote_execute?.should be_false
    end
  end
end
