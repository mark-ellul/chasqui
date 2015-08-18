require 'timeout'

class Chasqui::Broker
  attr_reader :config

  extend Forwardable
  def_delegators :@config, :redis, :inbox, :logger

  ShutdownSignals = %w(INT QUIT ABRT TERM).freeze

  # The broker uses blocking redis commands, so we create a new redis connection
  # for the broker, to prevent unsuspecting clients from blocking forever.
  def initialize
    @config = Chasqui.config.dup
    @config.redis = Redis.new @config.redis.client.options
    logger.info "configured to fetch events from #{inbox} on #{redis.inspect}"
  end

  def start
    @shutdown_requested = nil

    ShutdownSignals.each do |signal|
      trap(signal) { @shutdown_requested = signal }
    end

    catch :shutdown do
      loop do
        begin
          # This timeout is a failsafe for an improperly configured broker
          Timeout::timeout(config.broker_poll_interval + 1) do
            if @shutdown_requested
              logger.info "broker received signal, #@shutdown_requested. shutting down"
              throw :shutdown
            else
              forward_event
            end
          end
        rescue TimeoutError
          logger.warn "broker poll interval exceeded for broker, #{self.class.name}"
        end
      end
    end
  end

  def forward_event
    raise NotImplementedError.new "please define #forward_event in a subclass of #{self.class.name}"
  end

  class << self
    def start
      Chasqui::MultiBroker.new.start
    end
  end

end

class Chasqui::MultiBroker < Chasqui::Broker

  def forward_event
    payload = redis.lrange(in_progress_queue, -1, -1).first
    unless payload.nil?
      logger.warn "detected failed event delivery, attempting recovery"
    end

    payload ||= redis.brpoplpush(inbox, in_progress_queue, timeout: config.broker_poll_interval)
    if payload.nil?
      logger.debug "reached timeout for broker poll interval: #{config.broker_poll_interval} seconds"
      return
    end

    event = JSON.parse payload
    qualified_event_name = "#{event['channel']}::#{event['event']}"
    logger.debug "received event: #{qualified_event_name}, payload: #{payload}"

    queues = redis.smembers "queues:#{event['channel']}"
    logger.debug "subscriber queues: #{queues.join(', ')}"

    redis.multi do
      queues.each { |queue| redis.rpush queue, payload }
      redis.rpop(in_progress_queue)
    end

    logger.debug "processed event: #{qualified_event_name}"
  end

  def in_progress_queue
    "#{inbox}:in_progress"
  end

end