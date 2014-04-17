require 'minitest/spec'
require 'minitest/autorun'

require 'metrics_plugin'

describe MetricsPluginTemplate do
  before do
    MetricsPlugin.repository.clear
  end

  describe '#repository' do
    describe 'with no plugins' do
      it 'is empty' do
        MetricsPlugin.repository.must_equal []
      end
    end

    describe 'with plugins' do
      it 'contains the plugins' do
        class Plugin1 < MetricsPlugin; end
        MetricsPlugin.repository.count.must_equal 1
        MetricsPlugin.repository[0].must_equal Plugin1

        class Plugin2 < MetricsPlugin; end
        MetricsPlugin.repository.count.must_equal 2
        MetricsPlugin.repository[1].must_equal Plugin2
      end
    end
  end
end

describe MetricsPlugin do
  it 'assigns @handler' do
    handler = 123
    mp = MetricsPlugin.new(handler)
    mp.instance_variable_get('@handler').must_equal handler
  end

  describe '#config' do
    it 'delegates to @handler' do
      handler = MiniTest::Mock.new
      handler.expect(:config, 123)
      mp = MetricsPlugin.new(handler)
      r = mp.config
      handler.verify
      r.must_equal 123
    end
  end

  describe '#name' do
    it 'returns a human readable name' do
      class MyCoolPlugin < MetricsPlugin; end
      name = MyCoolPlugin.new(nil).name
      name.must_equal 'mycool'
    end
  end

  describe '#enabled' do
    it 'returns true when plugin config does not exist' do
      handler = MiniTest::Mock.new
      handler.expect(:config, {})
      MetricsPlugin.new(handler).enabled?.must_equal true
    end

    it 'returns false when plugin config value is false' do
      handler = MiniTest::Mock.new
      2.times do
        handler.expect(:config, {'metrics' => {'enabled' => false}})
      end
      MetricsPlugin.new(handler).enabled?.must_equal false
    end

    it 'returns true when plugin config value is true' do
      handler = MiniTest::Mock.new
      2.times do
        handler.expect(:config, {'metrics' => {'enabled' => true}})
      end
      MetricsPlugin.new(handler).enabled?.must_equal true
    end

    it 'returns true when plugin config value is not false' do
      handler = MiniTest::Mock.new
      2.times do
        handler.expect(:config, {'metrics' => {'enabled' => 'abc'}})
      end
      MetricsPlugin.new(handler).enabled?.must_equal true
    end
  end
end
