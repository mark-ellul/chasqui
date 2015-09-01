require 'spec_helper'

describe Chasqui do
  it 'has a version number' do
    expect(Chasqui::VERSION).not_to be nil
  end

  describe '.configure' do
    before { reset_config }

    context 'defaults' do
      it { expect(Chasqui.channel).to eq('__default') }
      it { expect(Chasqui.inbox_queue).to eq('inbox') }
      it { expect(Chasqui.redis.client.db).to eq(0) }
      it { expect(Chasqui.config.broker_poll_interval).to eq(3) }
      it { expect(Chasqui.config.worker_backend).to eq(nil) }

      it do
        # remove chasqui's test environment logger
        Chasqui.config[:logger] = nil
        expect(Chasqui.logger).to be_kind_of(Logger)
      end

      it { expect(Chasqui.logger.level).to eq(Logger::INFO) }
      it { expect(Chasqui.logger.progname).to eq('chasqui') }
    end

    it 'configures the channel' do
      Chasqui.config.channel = 'com.example.test'
      expect(Chasqui.channel).to eq('com.example.test')
    end

    it 'accepts a block' do
      Chasqui.configure { |config| config.channel = 'com.example.test' }
      expect(Chasqui.channel).to eq('com.example.test')
    end

    it 'configures the inbox queue' do
      Chasqui.config.inbox_queue = 'foo'
      expect(Chasqui.inbox).to eq('foo')
    end

    it 'configures the broker poll interval' do
      Chasqui.config.broker_poll_interval = 1
      expect(Chasqui.config.broker_poll_interval).to eq(1)
    end

    context 'redis' do
      it 'accepts config options' do
        redis_config = { host: '10.0.3.24' }
        Chasqui.config.redis = redis_config
        expect(Chasqui.redis.client.host).to eq('10.0.3.24')
      end

      it 'accepts an initialized client' do
        redis = Redis.new db: 2
        Chasqui.config.redis = redis
        expect(Chasqui.redis.client.db).to eq(2)
      end

      it 'accepts URLs' do
        Chasqui.config.redis = 'redis://10.0.1.21:12345/0'
        expect(Chasqui.redis.client.host).to eq('10.0.1.21')
      end

      it 'uses a namespace' do
        Chasqui.redis.set 'foo', 'bar'
        expect(Chasqui.redis.redis.get 'chasqui:foo').to eq('bar')
      end
    end

    describe 'logger' do
      it 'accepts a log device' do
        logs = StringIO.new
        Chasqui.config.logger = logs
        Chasqui.logger.info "status"
        Chasqui.logger.warn "error"

        logs.rewind
        output = logs.read

        %w(chasqui INFO status WARN error).each do |text|
          expect(output).to match(text)
        end
      end

      it 'accepts a logger-like object' do
        fake_logger = FakeLogger.new
        Chasqui.config.logger = fake_logger
        expect(Chasqui.logger).to eq(fake_logger)
        expect(Chasqui.logger.progname).to eq('chasqui')
      end
    end
  end

  describe '.publish' do
    before { reset_chasqui }

    it 'pushes messages to the inbox queue' do
      payloads = [
        [1, 2, {'foo'=>'bar'}],
        [3, 4, {'biz'=>'baz'}]
      ]

      payloads.each do |args|
        Chasqui.publish 'test.event', *args
      end

      payloads.each do |data|
        event = JSON.load Chasqui.redis.rpop('inbox')
        expect(event['event']).to eq('test.event')
        expect(event['channel']).to eq('__default')
        expect(event['data']).to eq(data)
      end
    end

    it 'supports channels' do
      Chasqui.config.channel = 'my.app'
      Chasqui.publish 'test.event', :foo
      event = JSON.load Chasqui.redis.rpop('inbox')
      expect(event['event']).to eq('test.event')
      expect(event['channel']).to eq('my.app')
      expect(event['data']).to eq(['foo'])
    end
  end

  describe '.create_worker' do
    let(:subscriber) { j }

    it 'raises when no worker backend configured' do
      expect(-> {
        Chasqui.create_worker nil
      }).to raise_error(Chasqui::ConfigurationError)
    end

    it 'creates a resque worker' do
      subscriber = FakeSubscriber.new 'resque-queue', 'fake-channel'
      Chasqui.config.worker_backend = :resque
      worker = Chasqui.create_worker subscriber
      expect(worker.new).to be_kind_of(Chasqui::ResqueWorker)
    end

    if sidekiq_supported_ruby_version?
      it 'creates a sidekiq worker' do
        subscriber = FakeSubscriber.new 'sidekiq-queue', 'fake-channel'
        Chasqui.config.worker_backend = :sidekiq
        worker = Chasqui.create_worker subscriber
        expect(worker.new).to be_kind_of(Chasqui::SidekiqWorker)
      end
    end
  end

  describe '.subscribe' do
    before do
      reset_chasqui
      Chasqui.config.worker_backend = :resque
    end

    context 'resque worker subscriptions' do
      before { Resque.redis.namespace = 'blah' }

      it 'creates subscriptions using the appropriate redis namespace' do
        sub1 = Chasqui.subscribe queue: 'app1-queue', channel: 'com.example.admin'
        sub2 = Chasqui.subscribe queue: 'app2-queue', channel: 'com.example.admin'
        sub3 = Chasqui.subscribe queue: 'app1-queue', channel: 'com.example.video'

        queues = Chasqui.redis.smembers "subscribers:com.example.admin"
        expect(queues.sort).to eq(['resque/blah:queue:app1-queue', 'resque/blah:queue:app2-queue'])

        queues = Chasqui.redis.smembers "subscribers:com.example.video"
        expect(queues).to eq(['resque/blah:queue:app1-queue'])

        expect(Chasqui.subscriber('app1-queue')).to eq(sub1)
        expect(Chasqui.subscriber('app2-queue')).to eq(sub2)
        expect(sub1).to eq(sub3)
      end
    end

    context 'sidekiq worker subscriptions' do
      before do
        Chasqui.config.worker_backend = :sidekiq
      end

      it 'creates subscriptions using the appropriate redis namespace' do
        Chasqui.subscribe queue: 'app1-queue', channel: 'com.example.admin'
        queues = Chasqui.redis.smembers "subscribers:com.example.admin"
        expect(queues.sort).to eq(['sidekiq/queue:app1-queue'])

        Sidekiq.redis = { url: redis.client.options[:url], namespace: 'foobar' }
        Chasqui.subscribe queue: 'app2-queue', channel: 'com.example.video'
        queues = Chasqui.redis.smembers "subscribers:com.example.video"
        expect(queues.sort).to eq(['sidekiq/foobar:queue:app2-queue'])
      end
    end

    it 'returns a subscriber' do
      subscriber = Chasqui.subscribe queue: 'app1-queue', channel: 'com.example.admin'
      expect(subscriber).to be_kind_of(Chasqui::Subscriber)
    end

    it 'yields a subscriber configuration context' do
      $context = nil
      Chasqui.subscribe queue: 'foo', channel: 'bar' do
        $context = self
      end
      expect($context).to be_kind_of(Chasqui::Subscriber)
    end
  end

  describe '.subscriber_class_name' do
    it 'transforms queue name into a subscribe class name' do
      expect(Chasqui.subscriber_class_name('my-queue')).to eq(:Subscriber__my_queue)
      expect(Chasqui.subscriber_class_name('queue:my-queue')).to eq(:Subscriber__my_queue)
    end
  end
end
