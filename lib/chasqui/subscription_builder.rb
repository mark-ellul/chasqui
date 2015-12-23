module Chasqui
  module Workers
  end

  class SubscriptionBuilder
    attr_reader :subscriptions

    def initialize(subscriptions)
      @subscriptions = subscriptions
    end

    def on(channel, worker_or_callable, options={})
      worker = build_worker(channel, worker_or_callable, options)

      queue = full_queue_name(worker, options)
      set_queue_name(worker, queue)
      
      subscriptions.register Chasqui::Subscriber.new(channel, queue, worker)
    end

    def get_queue_name(worker)
      raise NotImplementedError
    end

    def set_queue_name(worker, queue)
      raise NotImplementedError
    end

    def define_worker_class(channel, callable, options)
      raise NotImplementedError
    end

    private

    def full_queue_name(worker, options={})
      queue = options.fetch :queue, get_queue_name(worker)
      prefix = options[:queue_name_prefix]

      prefix ? "#{prefix}:#{queue}" : queue
    end

    def build_worker(channel, worker_or_callable, options={})
      worker =
        if worker_or_callable.respond_to? :call
          define_worker_class(channel, worker_or_callable, options)
        else
          worker_or_callable
        end

      Chasqui::Workers.const_set worker_class_name(channel), worker

      worker
    end

    def worker_class_name(channel)
      segments = channel.split(/[^\w]/).map(&:downcase)
      name = segments.each { |w| w[0] = w[0].upcase }.join

      "#{name}Worker".freeze
    end
  end
end