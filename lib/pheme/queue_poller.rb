module Pheme
  class QueuePoller
    attr_accessor :queue_url, :queue_poller, :connection_pool_block, :format, :max_messages, :poller_configuration

    def initialize(queue_url:, connection_pool_block: false, max_messages: nil, format: :json, poller_configuration: {})
      raise ArgumentError, "must specify non-nil queue_url" unless queue_url.present?
      @queue_url = queue_url
      @queue_poller = Aws::SQS::QueuePoller.new(queue_url)
      @connection_pool_block = connection_pool_block
      @format = format
      @max_messages = max_messages
      @poller_configuration = {
        wait_time_seconds: 10, # amount of time a long polling receive call can wait for a mesage before receiving a empty response (which will trigger another polling request)
        idle_timeout: 20, # disconnects poller after 20 seconds of idle time
        skip_delete: true, # manually delete messages
      }.merge(poller_configuration || {})

      if max_messages
        queue_poller.before_request do |stats|
          throw :stop_polling if stats.received_message_count >= max_messages
        end
      end
    end

    def poll
      Pheme.log(:info, "Long-polling for messages on #{queue_url}")
      with_optional_connection_pool_block do
        queue_poller.poll(poller_configuration) do |message|
          data = parse_message(message)
          begin
            handle(data)
            queue_poller.delete_message(message)
          rescue => e
            Pheme.log(:error, "Exception: #{e.inspect}")
            Pheme.log(:error, e.backtrace.join("\n"))
            Pheme.rollbar(e, "#{self.class} failed to process message", data)
          end
        end
      end
      Pheme.log(:info, "Finished long-polling after #{@poller_configuration[:idle_timeout]} seconds.")
    end

    def parse_message(message)
      Pheme.log(:info, "Received JSON payload: #{message.body}")
      body = JSON.parse(message.body)
      case format
      when :csv
        parse_csv(body['Message'])
      when :json
        parse_json(body['Message'])
      else
        raise ArgumentError.new("Unknown format #{format}. Valid formats: :csv, :json.")
      end
    end

    def parse_csv(message_contents)
      parsed_body = SmarterCSV.process(StringIO.new(message_contents))
      parsed_body.map{ |item| RecursiveOpenStruct.new(item, recurse_over_arrays: true) }
    end

    def parse_json(message_contents)
      parsed_body = JSON.parse(message_contents)
      if parsed_body.instance_of? Array
        parsed_body.map{ |item| RecursiveOpenStruct.new(item, recurse_over_arrays: true) }
      else
        RecursiveOpenStruct.new(parsed_body, recurse_over_arrays: true)
      end
    end

    def handle(message)
      raise NotImplementedError
    end

  private

    def with_optional_connection_pool_block(&blk)
      if connection_pool_block
        ActiveRecord::Base.connection_pool.with_connection { blk.call }
      else
        blk.call
      end
    end
  end
end
