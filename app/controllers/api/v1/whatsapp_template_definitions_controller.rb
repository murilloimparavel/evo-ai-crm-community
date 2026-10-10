# frozen_string_literal: true

module Api
  module V1
    class WhatsappTemplateDefinitionsController < BaseController
      require_permissions({ index: 'message_templates.read', create: 'message_templates.manage',
                            update: 'message_templates.manage', publish: 'message_templates.manage',
                            targets: 'message_templates.read' })

      def targets
        authorize MessageTemplate, :index?, policy_class: MessageTemplatePolicy
        channels = Channel::Whatsapp.where(provider: 'whatsapp_cloud').includes(:inbox)
        grouped = channels.filter_map do |channel|
          waba_id = channel.provider_config.to_h['waba_id'].presence || channel.provider_config.to_h['business_account_id'].presence
          next if waba_id.blank? || channel.inbox.blank?

          [waba_id.to_s, { inbox_id: channel.inbox.id, name: channel.inbox.name, phone_number: channel.phone_number }]
        end.group_by(&:first)
        success_response(data: grouped.map { |waba_id, entries| { waba_id: waba_id, inboxes: entries.map(&:last) } })
      end

      def index
        authorize MessageTemplate, :index?, policy_class: MessageTemplatePolicy
        definitions = WhatsappTemplateDefinition.includes(:publications).order(:name)
        definitions = definitions.where('name ILIKE ?', "%#{params[:search]}%") if params[:search].present?
        definitions = definitions.where(category: params[:category]) if params[:category].present?
        definitions = definitions.where(language: params[:language]) if params[:language].present?
        definitions = definitions.joins(:publications).where(whatsapp_template_publications: { waba_id: params[:waba_id] }).distinct if params[:waba_id].present? && params[:status] != 'not_submitted'
        if params[:status] == 'not_submitted'
          publications = WhatsappTemplatePublication.all
          publications = publications.where(waba_id: params[:waba_id]) if params[:waba_id].present?
          definitions = definitions.where.not(id: publications.select(:whatsapp_template_definition_id))
        elsif params[:status].present?
          definitions = definitions.joins(:publications).where(whatsapp_template_publications: { status: params[:status] }).distinct
        end
        success_response(data: definitions.map { |definition| serialize(definition) })
      end

      def create
        authorize MessageTemplate, :create?, policy_class: MessageTemplatePolicy
        definition = WhatsappTemplateDefinition.create!(definition_params)
        success_response(data: serialize(definition), status: :created)
      rescue ActiveRecord::RecordInvalid => e
        error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, status: :unprocessable_entity)
      rescue ActiveRecord::RecordNotUnique
        error_response(ApiErrorCodes::VALIDATION_ERROR, 'A template with this name already exists', status: :unprocessable_entity)
      end

      def update
        authorize MessageTemplate, :update?, policy_class: MessageTemplatePolicy
        definition = WhatsappTemplateDefinition.find(params[:id])
        updates = definition_params
        content_updates = updates.slice(:name, :language, :category, :content, :components, :variables).to_h
        content_changes = content_updates.any? { |key, value| definition.public_send(key) != value }
        submission_locked = definition.publications.any? do |publication|
          publication.external_template_id.present? || !publication.status.in?(%w[not_submitted failed])
        end
        if submission_locked && content_changes
          return error_response(ApiErrorCodes::VALIDATION_ERROR,
                                'This definition has been submitted to Meta. Create a new definition to change its content.',
                                status: :unprocessable_entity)
        end
        WhatsappTemplateDefinition.transaction do
          definition.update!(updates)
          if content_changes
            definition.publications.where(status: 'failed', external_template_id: nil).update_all(
              status: 'not_submitted', raw_status: nil, meta_category: nil, quality: nil,
              rejected_reason: nil, operational_error: nil, submitted_at: nil, synced_at: nil,
              updated_at: Time.current
            )
          end
        end
        success_response(data: serialize(definition))
      rescue ActiveRecord::RecordNotFound
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Template definition not found', status: :not_found)
      rescue ActiveRecord::RecordInvalid => e
        error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, status: :unprocessable_entity)
      end

      def publish
        authorize MessageTemplate, :create?, policy_class: MessageTemplatePolicy
        definition = WhatsappTemplateDefinition.find(params[:id])
        waba_ids = Array(params[:waba_ids]).map(&:to_s).reject(&:blank?).uniq
        return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Select at least one WABA', status: :unprocessable_entity) if waba_ids.empty?
        unknown_wabas = waba_ids - configured_waba_ids
        return error_response(ApiErrorCodes::VALIDATION_ERROR, 'One or more selected WABAs are not connected to a WhatsApp Cloud inbox', status: :unprocessable_entity) if unknown_wabas.any?

        publications = waba_ids.map do |waba_id|
          Whatsapp::TemplatePublicationService.new(definition: definition, waba_id: waba_id).call
        rescue Whatsapp::TemplatePublicationService::PublicationError => e
          definition.publications.find_by(waba_id: waba_id) ||
            definition.publications.create!(waba_id: waba_id, status: 'failed', operational_error: e.message.truncate(500))
        end
        success_response(data: publications.map { |publication| serialize_publication(publication) })
      rescue ActiveRecord::RecordNotFound
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Template definition not found', status: :not_found)
      end

      private

      def definition_params
        params.require(:definition).permit(:name, :language, :category, :content, :active,
                                           components: [
                                             :type, :format, :text, :url,
                                             { buttons: [:type, :text, :url, :phone_number] }
                                           ],
                                           variables: [:name, :label, :type, :required, :example, :source, :component])
      end

      def configured_waba_ids
        Channel::Whatsapp.where(provider: 'whatsapp_cloud').includes(:inbox).filter_map do |channel|
          next if channel.inbox.blank?

          config = channel.provider_config.to_h
          (config['waba_id'].presence || config['business_account_id'].presence)&.to_s
        end.uniq
      end

      def serialize(definition)
        { id: definition.id, name: definition.name, language: definition.language,
          category: definition.category, content: definition.content, components: definition.components,
          variables: definition.variables, active: definition.active,
          publications: definition.publications.map { |publication| serialize_publication(publication) } }
      end

      def serialize_publication(publication)
        { id: publication.id, waba_id: publication.waba_id,
          external_template_id: publication.external_template_id, status: publication.status,
          raw_status: publication.raw_status, meta_category: publication.meta_category,
          quality: publication.quality, rejected_reason: publication.rejected_reason,
          operational_error: publication.operational_error, submitted_at: publication.submitted_at,
          synced_at: publication.synced_at }
      end
    end
  end
end
