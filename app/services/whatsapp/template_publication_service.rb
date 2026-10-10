# frozen_string_literal: true

class Whatsapp::TemplatePublicationService
  class PublicationError < StandardError; end

  def initialize(definition:, waba_id:)
    @definition = definition
    @waba_id = waba_id.to_s
  end

  def call
    publication = find_or_create_publication
    publication.with_lock do
      return publication if publication.external_template_id.present? || publication.status.in?(%w[submitting submission_unknown])

      channel = cloud_channels.first
      raise PublicationError, 'No WhatsApp Cloud inbox is connected to this WABA' unless channel

      payload = template_payload
      publication.update!(status: 'submitting', operational_error: nil)
      begin
        template = channel.provider_service.create_template(payload)
      rescue StandardError => e
        http_status = e.message[/HTTP (\d{3})/, 1].to_i
        if http_status.between?(400, 499)
          publication.update!(status: 'failed', operational_error: "Meta rejected the submission (HTTP #{http_status})")
        end
        raise e
      end
      external_id = template&.external_template_id
      if external_id.blank?
        publication.update!(status: 'submission_unknown', submitted_at: Time.current)
        raise PublicationError, 'Meta accepted the request but the template ID is not available yet; sync this WABA before retrying'
      end

      raw_status = template.settings.to_h['status']
      publication.update!(external_template_id: external_id.to_s,
                          status: WhatsappTemplatePublication::META_STATUSES[raw_status.to_s.upcase] || 'unknown',
                          raw_status: raw_status, meta_category: template.category,
                          submitted_at: Time.current, synced_at: Time.current)
      propagate_to_sibling_channels(template, cloud_channels)
      publication
    end
  rescue PublicationError => e
    persisted_status = publication&.reload&.status
    status = if e.message.start_with?('Meta accepted the request') || persisted_status == 'submitting'
               'submission_unknown'
             else
               persisted_status || 'not_submitted'
             end
    publication&.update!(status: status,
                         operational_error: e.message.truncate(500))
    raise
  rescue StandardError => e
    # Provider timeouts are ambiguous: never blindly repeat a possibly accepted Meta submission.
    if publication
      http_status = e.message[/HTTP (\d{3})/, 1].to_i
      status = http_status.between?(400, 499) ? 'failed' : 'submission_unknown'
      publication.update!(status: status, operational_error: safe_error(e))
    end
    raise PublicationError, safe_error(e)
  end

  private

  def find_or_create_publication
    @definition.publications.find_or_create_by!(waba_id: @waba_id)
  rescue ActiveRecord::RecordNotUnique
    @definition.publications.find_by!(waba_id: @waba_id)
  end

  def cloud_channels
    Channel::Whatsapp.where(provider: 'whatsapp_cloud').where(
      "provider_config ->> 'waba_id' = :id OR provider_config ->> 'business_account_id' = :id", id: @waba_id
    ).order(:id).to_a
  end

  def template_payload
    parameter_format = named_parameters? ? 'NAMED' : 'POSITIONAL'
    {
      'name' => @definition.name,
      'language' => @definition.language,
      'category' => @definition.category,
      'parameter_format' => parameter_format,
      'components' => components_with_examples(parameter_format),
      'variables' => @definition.variables
    }
  end

  def named_parameters?
    @definition.components.any? do |component|
      component['type'] == 'BODY' && component['text'].to_s.match?(/\{\{\s*[a-zA-Z_][a-zA-Z0-9_.]*\s*\}\}/)
    end
  end

  def components_with_examples(parameter_format)
    variable_map = @definition.variables.index_by { |variable| variable['name'].to_s }
    @definition.components.map do |component|
      text = component['text'].to_s
      names = text.scan(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/).flatten.uniq
      names.sort_by!(&:to_i) if parameter_format == 'POSITIONAL'
      next component if names.empty?

      missing = names.reject { |name| variable_map[name].is_a?(Hash) && variable_map[name]['example'].present? }
      raise PublicationError, "Provide an example for each variable before publishing: #{missing.join(', ')}" if missing.any?

      examples = names.map { |name| variable_map[name]['example'].to_s }
      if parameter_format == 'NAMED'
        named_examples = names.zip(examples).map { |name, example| { 'param_name' => name, 'example' => example } }
        example_key = component['type'] == 'HEADER' ? 'header_text_named_params' : 'body_text_named_params'
        component.merge('example' => { example_key => named_examples })
      elsif component['type'] == 'HEADER'
        component.merge('example' => { 'header_text' => examples })
      else
        component.merge('example' => { 'body_text' => [examples] })
      end
    end
  end

  # Existing chat and automation selectors read channel-bound MessageTemplate rows.
  # Keep those consumers working while the publication record remains the shared WABA state.
  def propagate_to_sibling_channels(source, channels)
    channels.each do |sibling|
      next if sibling.id == source.channel_id
      existing = sibling.message_templates.find_or_initialize_by(name: source.name, language: source.language)
      existing.assign_attributes(content: source.content, category: source.category,
                                 template_type: source.template_type, components: source.components,
                                 variables: source.variables, media_type: source.media_type,
                                 media_url: source.media_url, settings: source.settings,
                                 metadata: source.metadata.to_h.merge('waba_id' => @waba_id))
      existing.save!
    rescue StandardError => e
      Rails.logger.warn("WhatsApp Cloud template copy sync failed for channel #{sibling.id} (#{e.class})")
    end
  end

  def safe_error(error)
    error.message.to_s
         .gsub(/Bearer\s+[^\s"']+/i, '[REDACTED]')
         .gsub(/(?:access_token|api_key|channel_token|token)=[^\s&"']+/i, '[REDACTED]')
         .truncate(500)
  end
end
