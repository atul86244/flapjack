# Sends events to Flapjack for notification routing. See http://flapjack.io/
#
# This extension requires Flapjack >= 2.0.0 and Sensu >= 0.21.0
#
# In order for Flapjack to keep its entities up to date, it is necssary to set
# metric to "true" for each check that is using the flapjack handler extension.
#
# Usage in Sensu:
#
# define a handler:
#
#  sensu_handler 'flapjack' do
#    '127.0.0.1'
#    port: 6380
#  end
#
# which would result in:
#
# {
#   "flapjack": {
#      "host": "127.0.0.1",
#      "port": 6380
#   }
# }
#

require 'sensu/redis'
require 'json'

module Sensu
  module Extension
    class Flapjack < Handler
      def name
        'flapjack'
      end

      def description
        'sends sensu events to the flapjack redis queue'
      end

      def options
        return @options if @options

        @options = {
          host: '127.0.0.1',
          port: 6379,
          channel: 'events',
          db: 0
        }

        if @settings[:flapjack].is_a?(Hash)
          @options.merge!(@settings[:flapjack])
        end

        @options
      end

      def definition
        {
          type: 'extension',
          name: name,
          mutator: 'ruby_hash'
        }
      end

      def post_init
        Sensu::Redis.connect(options) do |connection|
          @redis = connection

          @redis.on_error do |_error|
            @logger.warn("Flapjack Redis is not available on #{options[:host]}")
          end

          @redis.before_reconnect do
            @logger.warn("reconnecting to redis")
          end

          @redis.after_reconnect do
            @logger.info("reconnected to redis")
          end

          yield(@redis) if block_given?
        end
      end

      def run(event)
        client = event[:client]
        check = event[:check]

        tags = []
        tags.concat(client[:tags]) if client[:tags].is_a?(Array)
        tags.concat(check[:tags]) if check[:tags].is_a?(Array)
        tags << client[:environment] unless client[:environment].nil?

        if check[:subscribers].nil? || check[:subscribers].empty?
          tags.concat(client[:subscriptions])
        else
          tags.concat(client[:subscriptions] - (client[:subscriptions] - check[:subscribers]))
        end

        details = ['Address:' + client[:address]]
        details << 'Tags:' + tags.join(',')
        details << "Raw Output: #{check[:output]}" if check[:notification]

        flapjack_event = {
          entity: client[:name],
          check: check[:name],
          type: 'service',
          state: Sensu::SEVERITIES[check[:status]] || 'unknown',
          summary: check[:notification] || check[:output],
          details: details.join(' '),
          time: check[:executed],
          tags: tags
        }

        @redis.lpush(options[:channel], flapjack_event.to_json)
        @redis.lpush("events_actions", "+")

        yield 'sent an event to the flapjack redis queue', 0
      end
    end
  end
end
