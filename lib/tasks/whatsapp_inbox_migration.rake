# frozen_string_literal: true

namespace :whatsapp do
  namespace :inbox_migration do
    def whatsapp_inbox_migration
      Whatsapp::EvolutionInboxMigration.new(
        source_inbox_id: ENV.fetch('SOURCE_INBOX_ID'),
        target_inbox_id: ENV.fetch('TARGET_INBOX_ID')
      )
    end

    desc 'Read-only preview of an Evolution to WhatsApp Cloud inbox migration'
    task preview: :environment do
      puts JSON.pretty_generate(whatsapp_inbox_migration.preview)
    end

    desc 'Move Evolution inbox history to WhatsApp Cloud in resumable batches'
    task migrate: :environment do
      puts JSON.pretty_generate(whatsapp_inbox_migration.migrate!(
        confirm_source_inbox_id: ENV.fetch('CONFIRM_SOURCE_INBOX_ID'),
        confirm_target_inbox_id: ENV.fetch('CONFIRM_TARGET_INBOX_ID')
      ))
    end

    desc 'Retire an empty source inbox after migration and validation'
    task retire: :environment do
      puts JSON.pretty_generate(whatsapp_inbox_migration.retire_source_inbox!(
        confirmation: ENV.fetch('CONFIRM_DELETE_SOURCE_INBOX_ID'),
        confirm_target_configuration_authoritative: ENV['CONFIRM_TARGET_CONFIGURATION_AUTHORITATIVE'] == 'true'
      ))
    end
  end
end
