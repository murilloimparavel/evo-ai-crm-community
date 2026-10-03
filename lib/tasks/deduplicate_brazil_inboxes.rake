# frozen_string_literal: true

namespace :contacts do
  desc 'Deduplicate Brazilian contact_inboxes and merge duplicate conversations (DRY_RUN=false to apply)'
  task deduplicate_brazil_inboxes: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'
    puts "=========================================================="
    puts "DEDUPLICATING BRAZILIAN CONTACT_INBOXES & CONVERSATIONS"
    puts "Mode: #{dry_run ? 'DRY RUN (no changes applied)' : 'LIVE EXECUTION (applying changes)'}"
    puts "=========================================================="

    # Find contacts with multiple contact_inboxes in the same WhatsApp inbox
    whatsapp_inbox = Inbox.where(channel_type: 'Channel::Whatsapp').first
    unless whatsapp_inbox
      puts "No WhatsApp inbox found. Exiting."
      next
    end

    puts "WhatsApp Inbox: #{whatsapp_inbox.name} (#{whatsapp_inbox.id})"

    duplicate_contacts = Contact.joins(:contact_inboxes)
                                .where(contact_inboxes: { inbox_id: whatsapp_inbox.id })
                                .group('contacts.id')
                                .having('count(contact_inboxes.id) > 1')

    puts "Found #{duplicate_contacts.count.size} contacts with multiple contact_inboxes in this inbox.\n"

    merged_count = 0
    messages_moved = 0
    inboxes_removed = 0

    duplicate_contacts.find_each do |contact|
      contact_inboxes = contact.contact_inboxes.where(inbox_id: whatsapp_inbox.id).order(created_at: :asc).to_a
      next if contact_inboxes.size <= 1

      # Canonical source_id according to PhoneNumberNormalizer
      canonical_digits = Whatsapp::PhoneNumberNormalizer.call(contact.phone_number)
      canonical_source = canonical_digits.presence || contact_inboxes.last.source_id

      # Choose canonical contact_inbox (the one matching canonical_source, or the oldest)
      canonical_ci = contact_inboxes.find { |ci| ci.source_id == canonical_source } || contact_inboxes.first
      duplicates = contact_inboxes - [canonical_ci]

      puts "Contact #{contact.name.presence || contact.id} (#{contact.phone_number}):"
      puts "  Canonical ContactInbox: #{canonical_ci.id} (source_id: #{canonical_ci.source_id})"

      duplicates.each do |dup_ci|
        puts "  Duplicate ContactInbox: #{dup_ci.id} (source_id: #{dup_ci.source_id})"

        # Find conversations belonging to the duplicate contact_inbox
        dup_conversations = dup_ci.conversations.to_a
        canonical_conversation = canonical_ci.conversations.order(created_at: :desc).first

        dup_conversations.each do |dup_conv|
          if canonical_conversation && canonical_conversation.id != dup_conv.id
            puts "    Moving messages from Conversation #{dup_conv.id} -> #{canonical_conversation.id}"
            unless dry_run
              ActiveRecord::Base.transaction do
                dup_conv.messages.update_all(conversation_id: canonical_conversation.id)
                # Keep conversation metadata
                dup_conv.update!(status: :resolved)
              end
            end
            messages_moved += dup_conv.messages.count
          elsif !canonical_conversation
            # If canonical contact_inbox had no conversation, reassign this conversation to canonical_ci
            puts "    Reassigning Conversation #{dup_conv.id} to Canonical ContactInbox #{canonical_ci.id}"
            unless dry_run
              dup_conv.update!(contact_inbox_id: canonical_ci.id)
            end
            canonical_conversation = dup_conv
          end
        end

        unless dry_run
          # Remove duplicate contact_inbox safely
          dup_ci.destroy
        end
        inboxes_removed += 1
      end

      merged_count += 1
      puts "----------------------------------------------------------"
    end

    puts "\nSUMMARY:"
    puts "Contacts processed: #{merged_count}"
    puts "Messages moved: #{messages_moved}"
    puts "Duplicate contact_inboxes removed: #{inboxes_removed}"
    puts "Dry run completed. Set DRY_RUN=false to apply changes." if dry_run
  end
end
