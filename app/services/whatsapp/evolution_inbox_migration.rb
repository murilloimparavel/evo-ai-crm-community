# frozen_string_literal: true

module Whatsapp
  # Moves CRM history from a disconnected Evolution inbox to an existing
  # WhatsApp Cloud inbox. It never calls either provider and never creates
  # messages. Records keep their primary keys, timestamps, attachments, labels,
  # pipeline relations, and internal reply links.
  class EvolutionInboxMigration
    DEFAULT_BATCH_SIZE = 50
    DISCONNECTED_STATES = %w[close closed disconnected logged_out].freeze
    CLOUD_RECIPIENT_FORMAT = /\A(?:\+?\d{1,15}|[A-Z]{2}\.[a-zA-Z0-9]+)\z/.freeze

    class UnsafeMigration < StandardError; end

    def initialize(source_inbox_id:, target_inbox_id:, batch_size: DEFAULT_BATCH_SIZE)
      @source_inbox_id = source_inbox_id.to_s
      @target_inbox_id = target_inbox_id.to_s
      @batch_size = Integer(batch_size)
      raise ArgumentError, 'batch_size must be positive' unless @batch_size.positive?
    end

    # Read-only preview. Counts are aggregated and do not expose contact data.
    def preview
      source, target = load_inboxes!
      conversations = source.conversations
      source_contact_inboxes = ContactInbox.where(inbox_id: source.id,
                                                  id: conversations.select(:contact_inbox_id))
                                           .includes(:contact).to_a.uniq(&:contact_id)
      items = source_contact_inboxes.map do |contact_inbox|
        destination_for(contact_inbox)
      end
      blocked_reasons = items.select { |item| item[:kind] == :blocked }.each_with_object(Hash.new(0)) do |item, counts|
        counts[item[:reason]] += 1
      end
      target_contact_inbox_ids = items.filter_map { |item| item.dig(:contact_inbox, :id) }.uniq
      active_target_overlaps = Conversation.where(contact_inbox_id: target_contact_inbox_ids,
                                                   status: %i[open pending snoozed]).count
      source_contact_inbox_ids = ContactInbox.where(inbox_id: source.id).select(:id)
      conversations_without_source_link = conversations.where(contact_inbox_id: nil)
                                                        .or(conversations.where.not(contact_inbox_id: source_contact_inbox_ids)).count
      cross_inbox_reply_references = Message.where(inbox_id: source.id)
                                            .where("content_attributes::jsonb ? 'in_reply_to_external_id'").count
      reporting_events_without_conversation = ReportingEvent.where(inbox_id: source.id, conversation_id: nil).count

      {
        source_inbox: { id: source.id, name: source.name, provider: source.channel.provider,
                        connection: source.channel.provider_connection.to_h['connection'] },
        target_inbox: { id: target.id, name: target.name, provider: target.channel.provider },
        conversations: conversations.count,
        messages: source.messages.count,
        attachments: Attachment.where(attachable_type: 'Message', attachable_id: source.messages.select(:id)).count,
        active_conversations: conversations.where(status: %i[open pending snoozed]).count,
        pipeline_items: PipelineItem.joins(:conversation).where(conversations: { inbox_id: source.id }).count,
        reporting_events: ReportingEvent.where(inbox_id: source.id).count,
        reporting_events_without_conversation: reporting_events_without_conversation,
        contact_inboxes_used: conversations.select(:contact_inbox_id).distinct.count,
        target_contact_inboxes_reused: items.count { |item| item[:kind] == :existing },
        target_contact_inboxes_to_create: items.count { |item| item[:kind] == :create },
        unaddressable_contacts: blocked_reasons[:unsupported_cloud_recipient],
        identity_conflicts: blocked_reasons[:target_identity_conflict] + blocked_reasons[:invalid_target_recipient],
        ambiguous_contact_mappings: blocked_reasons[:ambiguous_source_contact] + blocked_reasons[:ambiguous_target_contact],
        missing_contact_links: blocked_reasons[:missing_contact_inbox] + conversations_without_source_link,
        blocked_reasons: blocked_reasons,
        active_target_overlaps: active_target_overlaps,
        cross_provider_reply_references: cross_inbox_reply_references,
        missing_inbox_members: source.inbox_members.where.not(
          user_id: target.inbox_members.select(:user_id)
        ).count,
        source_agent_bot_configured: source.agent_bot_inbox.present?,
        target_agent_bot_configured: target.agent_bot_inbox.present?,
        target_configuration_differences: configuration_differences(source, target),
        source_webhooks: source.webhooks.count,
        source_integrations: source.hooks.count
      }
    end

    # Resumable and idempotent: each small batch is atomic. A rerun picks up
    # only conversations that are still in the source inbox.
    def migrate!(confirm_source_inbox_id:, confirm_target_inbox_id:)
      verify_confirmation!(confirm_source_inbox_id, confirm_target_inbox_id)
      initial = preview
      raise UnsafeMigration, 'source inbox is connected; disconnect it before migration' unless DISCONNECTED_STATES.include?(initial.dig(:source_inbox, :connection).to_s)
      raise UnsafeMigration, "migration preflight has blockers: #{initial[:blocked_reasons].inspect}" if initial[:blocked_reasons].any?
      raise UnsafeMigration, 'one or more conversations have no source contact link' if initial[:missing_contact_links].positive?
      raise UnsafeMigration, 'active target conversations overlap migrated contacts; resolve them before migration' if initial[:active_target_overlaps].positive?
      raise UnsafeMigration, 'source inbox has hooks or webhooks; disable them before migration' if initial[:source_webhooks].positive? || initial[:source_integrations].positive?

      migrated = 0
      loop do
        batch = nil
        ActiveRecord::Base.transaction do
          source, target = load_inboxes!
          ensure_channels!(source, target)
          ensure_source_disconnected!(source)
          ensure_source_hooks_clear!(source)
          ensure_target_still_clear!(target)
          copy_memberships!(source, target)

          batch = source.conversations.order(:created_at, :id).limit(@batch_size).lock('FOR UPDATE').to_a
          batch.each { |conversation| migrate_conversation!(conversation, target) } if batch.any?
        end
        break if batch.empty?

        migrated += batch.length
      end

      ActiveRecord::Base.transaction do
        source, target = load_inboxes!
        ensure_source_disconnected!(source)
        ensure_target_still_clear!(target)
        raise UnsafeMigration, 'source conversations appeared during migration; rerun preview' if source.conversations.exists?
        raise UnsafeMigration, 'source messages remain outside migrated conversations' if source.messages.exists?
        raise UnsafeMigration, 'source hooks or webhooks appeared during migration' unless source.webhooks.none? && source.hooks.none?
        source.contact_inboxes.find_each do |contact_inbox|
          raise UnsafeMigration, 'source contact inbox still has conversations' if contact_inbox.conversations.exists?

          contact_inbox.destroy!
        end
        # Reporting rows that are scoped to an inbox but not to a conversation
        # remain useful after the historical inbox is retired.
        ReportingEvent.where(inbox_id: @source_inbox_id).update_all(inbox_id: @target_inbox_id)
      end

      { migrated_conversations: migrated, remaining_conversations: Inbox.find(@source_inbox_id).conversations.count,
        target_inbox_id: @target_inbox_id }
    end

    # Destructive final step, intentionally separate from the move. All
    # conversations/messages/events must already be in the target. The exact
    # source UUID is required as a confirmation string.
    def retire_source_inbox!(confirmation:, confirm_target_configuration_authoritative: false)
      raise UnsafeMigration, 'confirmation must exactly match the source inbox UUID' unless confirmation.to_s == @source_inbox_id

      ActiveRecord::Base.transaction do
        source, target = load_inboxes!
        ensure_channels!(source, target)
        ensure_source_disconnected!(source)
        ensure_source_hooks_clear!(source)
        differences = configuration_differences(source, target)
        if differences.any? && !confirm_target_configuration_authoritative
          raise UnsafeMigration, "review target configuration differences before retirement: #{differences.join(', ')}"
        end
        blockers = {
          conversations: source.conversations.count,
          messages: source.messages.count,
          reporting_events: ReportingEvent.where(inbox_id: source.id).count,
          webhooks: source.webhooks.count,
          integrations: source.hooks.count,
          contact_inboxes: source.contact_inboxes.count,
          inbox_members: source.inbox_members.count,
          agent_bot: source.agent_bot_inbox.present? ? 1 : 0,
          working_hours: source.working_hours.count
        }
        raise UnsafeMigration, "source inbox still has dependent data: #{blockers.inspect}" if blockers.values.any?(&:positive?)

        channel = source.channel
        channel.define_singleton_method(:disconnect_channel_provider) { true }
        channel.define_singleton_method(:evolution_hub_cleanup) { true }
        channel.destroy!
      end

      { retired_inbox_id: @source_inbox_id, target_inbox_id: @target_inbox_id }
    end

    private

    def load_inboxes!
      source = Inbox.includes(:channel, :agent_bot_inbox).find(@source_inbox_id)
      target = Inbox.includes(:channel, :agent_bot_inbox).find(@target_inbox_id)
      ensure_channels!(source, target)
      [source, target]
    end

    def ensure_channels!(source, target)
      raise UnsafeMigration, 'source and target inboxes must be different' if source.id == target.id
      raise UnsafeMigration, 'source inbox must use the Evolution provider' unless source.channel_type == 'Channel::Whatsapp' && source.channel.provider == 'evolution'
      raise UnsafeMigration, 'target inbox must use the WhatsApp Cloud provider' unless target.channel_type == 'Channel::Whatsapp' && target.channel.provider == 'whatsapp_cloud'
      hub_config = target.channel.provider_config.to_h['evolution_hub']
      raise UnsafeMigration, 'target WhatsApp channel must be Hub-managed' unless hub_config.is_a?(Hash)
    end

    def ensure_source_disconnected!(source)
      state = source.channel.provider_connection.to_h['connection'].to_s
      return if DISCONNECTED_STATES.include?(state)

      raise UnsafeMigration, 'source inbox must remain disconnected'
    end

    def ensure_target_still_clear!(target)
      source_contacts = Conversation.where(inbox_id: @source_inbox_id).select(:contact_id)
      overlaps = Conversation.where(inbox_id: target.id, contact_id: source_contacts,
                                    status: %i[open pending snoozed]).count
      raise UnsafeMigration, 'active target conversations appeared during migration; rerun preview' if overlaps.positive?
    end

    def ensure_source_hooks_clear!(source)
      return if source.webhooks.none? && source.hooks.none?

      raise UnsafeMigration, 'source inbox has hooks or webhooks; disable them before migration'
    end

    def verify_confirmation!(source_id, target_id)
      raise UnsafeMigration, 'source inbox confirmation does not match' unless source_id.to_s == @source_inbox_id
      raise UnsafeMigration, 'target inbox confirmation does not match' unless target_id.to_s == @target_inbox_id
    end

    def destination_for(source_contact_inbox)
      return { kind: :blocked, reason: :missing_contact_inbox } unless source_contact_inbox&.contact

      target_matches = ContactInbox.where(inbox_id: @target_inbox_id, contact_id: source_contact_inbox.contact_id).limit(2).to_a
      return { kind: :blocked, reason: :ambiguous_target_contact } if target_matches.length > 1
      return { kind: :existing, contact_inbox: target_matches.first } if target_matches.one? && valid_cloud_recipient?(target_matches.first.source_id)
      return { kind: :blocked, reason: :invalid_target_recipient } if target_matches.one?

      source_id = cloud_source_id(source_contact_inbox.contact)
      return { kind: :blocked, reason: :unsupported_cloud_recipient } unless source_id

      owner = ContactInbox.find_by(inbox_id: @target_inbox_id, source_id: source_id)
      return { kind: :blocked, reason: :target_identity_conflict } if owner && owner.contact_id != source_contact_inbox.contact_id

      { kind: owner ? :existing : :create, contact_inbox: owner, source_id: source_id }
    end

    def cloud_source_id(contact)
      phone = contact.phone_number.to_s.gsub(/\D/, '')
      return phone if phone.match?(/\A\d{10,15}\z/)

      source_ids = ContactInbox.where(inbox_id: @source_inbox_id, contact_id: contact.id).distinct.pluck(:source_id)
      return source_ids.first if source_ids.one? && valid_cloud_recipient?(source_ids.first)

      nil
    end

    def valid_cloud_recipient?(value)
      value.to_s.match?(CLOUD_RECIPIENT_FORMAT)
    end

    def copy_memberships!(source, target)
      source.inbox_members.where.not(user_id: target.inbox_members.select(:user_id)).find_each do |membership|
        InboxMember.create!(inbox_id: target.id, user_id: membership.user_id)
      end
    end

    def configuration_differences(source, target)
      differences = []
      differences << 'inbox_settings' unless inbox_settings(source) == inbox_settings(target)
      differences << 'agent_bot' unless agent_bot_settings(source) == agent_bot_settings(target)
      differences << 'working_hours' unless working_hours_settings(source) == working_hours_settings(target)
      differences
    end

    def inbox_settings(inbox)
      %w[greeting_enabled greeting_message out_of_office_message working_hours_enabled timezone
         enable_auto_assignment auto_assignment_config allow_messages_after_resolved lock_to_single_conversation
         default_conversation_status csat_survey_enabled csat_config].index_with do |attribute|
        inbox.public_send(attribute)
      end
    end

    def agent_bot_settings(inbox)
      inbox.agent_bot_inbox&.attributes&.except('id', 'inbox_id', 'created_at', 'updated_at')
    end

    def working_hours_settings(inbox)
      inbox.working_hours.order(:day_of_week).map do |working_hour|
        working_hour.attributes.except('id', 'inbox_id', 'created_at', 'updated_at')
      end
    end

    def migrate_conversation!(conversation, target)
      source_contact_inbox = conversation.contact_inbox
      destination = destination_for(source_contact_inbox)
      raise UnsafeMigration, "conversation recipient mapping blocked: #{destination[:reason]}" if destination[:kind] == :blocked

      target_contact_inbox = destination[:contact_inbox] || ContactInbox.create!(
        inbox_id: target.id,
        contact_id: source_contact_inbox.contact_id,
        source_id: destination.fetch(:source_id),
        hmac_verified: false
      )

      marker = conversation.additional_attributes.to_h.merge(
        'channel_migration' => {
          'from_inbox_id' => @source_inbox_id,
          'kind' => 'evolution_to_whatsapp_cloud',
          'migrated_at' => Time.current.utc.iso8601
        }
      )
      conversation.update_columns(inbox_id: target.id, contact_inbox_id: target_contact_inbox.id,
                                  additional_attributes: marker)
      conversation.messages.update_all(inbox_id: target.id)
      ReportingEvent.where(conversation_id: conversation.id, inbox_id: @source_inbox_id)
                    .update_all(inbox_id: target.id)
    end
  end
end
