# frozen_string_literal: true

module Conversations
  # Batch data used by ConversationSerializer so large conversation collections
  # do not issue one unread-count or latest-message query per conversation.
  module SerializationData
    UNREAD_COUNTS_SQL = <<~SQL.squish
      SELECT c.id AS conversation_id,
             (
               SELECT COUNT(*)
               FROM messages m
               WHERE m.conversation_id = c.id
                 AND m.message_type = %<incoming_type>s
                 AND m.created_at > COALESCE(c.agent_last_seen_at, to_timestamp(0))
                 AND (m.content_attributes->>'read') IS DISTINCT FROM 'true'
             )::integer AS unread_count
      FROM conversations c
      WHERE c.id IN (%<conversation_ids>s)
    SQL

    LAST_NON_ACTIVITY_MESSAGES_SQL = <<~SQL.squish
      SELECT c.id AS conversation_id, m.id AS message_id
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT messages.id
        FROM messages
        WHERE messages.conversation_id = c.id
          AND messages.message_type != %<activity_type>s
        ORDER BY messages.created_at DESC, messages.id DESC
        LIMIT 1
      ) m ON TRUE
      WHERE c.id IN (%<conversation_ids>s)
        AND m.id IS NOT NULL
    SQL

    module_function

    def unread_counts_for(conversation_ids)
      return {} if conversation_ids.blank?

      connection = ActiveRecord::Base.connection
      sql = format(UNREAD_COUNTS_SQL,
                   incoming_type: Message.message_types[:incoming],
                   conversation_ids: quoted_uuid_list(conversation_ids, connection))

      connection.exec_query(sql).to_a.each_with_object({}) do |row, memo|
        unread_count = row['unread_count'].to_i
        memo[row['conversation_id']] = unread_count if unread_count.positive?
      end
    end

    def last_non_activity_messages_for(conversation_ids)
      return {} if conversation_ids.blank?

      connection = ActiveRecord::Base.connection
      sql = format(LAST_NON_ACTIVITY_MESSAGES_SQL,
                   activity_type: Message.message_types[:activity],
                   conversation_ids: quoted_uuid_list(conversation_ids, connection))

      rows = connection.exec_query(sql).to_a
      return {} if rows.empty?

      messages_by_id = load_latest_messages(rows)

      rows.each_with_object({}) do |row, memo|
        message = messages_by_id[row['message_id']]
        memo[row['conversation_id']] = message if message
      end
    end

    def quoted_uuid_list(ids, connection)
      ids.map { |id| connection.quote(id) }.join(', ')
    end

    def load_latest_messages(rows)
      message_ids = rows.pluck('message_id').compact.uniq
      Message.unscoped.where(id: message_ids).includes(:sender, :attachments).index_by(&:id)
    end

    private_class_method :quoted_uuid_list, :load_latest_messages
  end
end
