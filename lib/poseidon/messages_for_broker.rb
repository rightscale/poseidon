module Poseidon
  # Messages that should be sent to a particular broker.
  # @api private
  class MessagesForBroker
    attr_reader :broker_id, :messages

    def initialize(broker_id)
      @broker_id = broker_id
      @topics = {}
      @messages = []
    end

    # Add a messages for this broker
    def add(message, partition_id)
      @messages << message

      @topics[message.topic] ||= {}
      @topics[message.topic][partition_id] ||= []
      @topics[message.topic][partition_id] << message
    end

    # Build protocol objects for this broker!
    def build_protocol_objects(compression_config)
      @topics.map do |topic, messages_by_partition|
        codec = compression_config.compression_codec_for_topic(topic)

        messages_for_partitions = messages_by_partition.map do |partition, messages|
          message_set = MessageSet.new(messages)
          if codec
            Protocol::MessagesForPartition.new(partition, message_set.compress(codec))
          else
            Protocol::MessagesForPartition.new(partition, message_set)
          end
        end
        Protocol::MessagesForTopic.new(topic, messages_for_partitions)
      end
    end

    # Put any errors here that should not be retried (e.g. results in messages
    # persisted by one or more Kafka brokers, will always fail, etc.)
    NOT_RETRYABLE = [
      Poseidon::Errors::InvalidMessage,
      Poseidon::Errors::InvalidMessageSize,
      Poseidon::Errors::MessageSizeTooLarge
    ]

    def successfully_sent(producer_response)
      failed = []
      abort_retry = false
      producer_response.topic_response.each do |topic_response|
        topic_response.partitions.each do |partition|
          if partition.error_class
            abort_retry = NOT_RETRYABLE.include?(partition.error_class)
            Poseidon.logger.debug { "Received #{partition.error_class} when attempting to send messages to #{topic_response.topic} on #{partition.partition}" }
            failed.push(*@topics[topic_response.topic][partition.partition])
          end
        end
      end

      return [@messages - failed, abort_retry]
    end
  end
end
