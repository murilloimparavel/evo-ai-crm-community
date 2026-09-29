#######################################
# To create a whatsapp provider
# - Inherit this as the base class.
# - Implement `send_message` method in your child class.
# - Implement `send_template_message` method in your child class.
# - Implement `sync_templates` method in your child class.
# - Implement `validate_provider_config` method in your child class.
# - Use Childclass.new(whatsapp_channel: channel).perform.
######################################

class Whatsapp::Providers::BaseService
  pattr_initialize [:whatsapp_channel!]

  # Reason of the last failed send, for the caller to persist on the message.
  attr_reader :last_delivery_error, :last_delivery_status

  def send_message(_phone_number, _message)
    raise 'Overwrite this method in child class'
  end

  def send_template(_phone_number, _template_info)
    raise 'Overwrite this method in child class'
  end

  def sync_template
    raise 'Overwrite this method in child class'
  end

  def validate_provider_config
    raise 'Overwrite this method in child class'
  end

  # Meta Graph shape as the default; a non-JSON body (proxy 502) parses to a
  # String, which has no #dig — fall back to the raw body.
  def error_message(response)
    parsed = response.respond_to?(:parsed_response) ? response.parsed_response : nil
    status = response.respond_to?(:code) ? response.code : nil
    details = if parsed.is_a?(Hash)
                error = parsed['error']
                provider_code = error.is_a?(Hash) ? error['code'] : nil
                provider_message = extract_provider_error_detail(parsed['response']) ||
                                   extract_provider_error_detail(parsed['message']) ||
                                   extract_provider_error_detail(parsed['details']) ||
                                   extract_provider_error_detail(parsed['detail']) ||
                                   extract_provider_error_detail(error)

                if provider_message.present?
                  if provider_code.present? && !provider_message.include?(provider_code.to_s)
                    "#{provider_code}: #{provider_message}"
                  else
                    provider_message
                  end
                else
                  provider_code.presence || "Provider returned HTTP #{status}"
                end
              elsif preserve_non_json_error_body? && response.respond_to?(:body) && response.body.present?
                response.body
              else
                "Provider returned HTTP #{status}"
              end

    details.gsub(/[\r\n\t]/, ' ')
      .gsub(/Bearer\s+[A-Za-z0-9._-]+/i, 'Bearer [redacted]')
      .gsub(/\b(api[_ -]?key|admin[_ -]?token|access[_ -]?token|authorization)\b\s*[:=]\s*["']?[^,\s"'}]+/i, '\\1=[redacted]')
      .gsub(/\b[\w.+-]+@(?:s\.whatsapp\.net|g\.us|lid)\b/i, '[recipient]')
      .gsub(/\+?\d[\d\s().-]{6,}\d/, '[number]')
      .gsub(/[A-Za-z0-9_-]{40,}/, '[redacted]')
      .truncate(240)
  end

  def extract_provider_error_detail(value)
    case value
    when String
      value.presence
    when Array
      value.filter_map { |item| extract_provider_error_detail(item) }.join('; ').presence
    when Hash
      %w[message detail details error].each do |key|
        detail = extract_provider_error_detail(value[key])
        return detail if detail.present?
      end
      nil
    end
  end
  private :extract_provider_error_detail

  def preserve_non_json_error_body?
    false
  end

  def process_response(response)
    parsed_response = response.parsed_response
    if response.success? && parsed_response['error'].blank?
      parsed_response['messages'].first['id']
    else
      handle_error(response)
      nil
    end
  end

  def handle_error(response)
    # Provider responses can contain contact data and echoed payloads. Log only
    # the HTTP status and a bounded, sanitized provider error for diagnosis.
    status = response.respond_to?(:code) ? response.code : nil
    delivery_error = error_message(response)
    Rails.logger.error("[WhatsAppProvider] response_status=#{status} error=#{delivery_error}")
    @last_delivery_status = status.to_i
    # Records only; SendOnWhatsappService owns the status marking.
    # https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes/#sample-response
    @last_delivery_error = delivery_error
  end

  def create_buttons(items)
    buttons = []
    items.each do |item|
      button = { :type => 'reply', 'reply' => { 'id' => item['value'], 'title' => item['title'] } }
      buttons << button
    end
    buttons
  end

  def create_rows(items)
    rows = []
    items.each do |item|
      row = { 'id' => item['value'], 'title' => item['title'] }
      rows << row
    end
    rows
  end

  def html_to_whatsapp(text)
    return '' if text.blank?

    result = text.dup
    result.gsub!(%r{<br\s*/?>}i, "\n")
    result.gsub!(%r{</p>\s*<p[^>]*>}i, "\n\n")
    result.gsub!(%r{<li[^>]*>}i, "- ")
    result.gsub!(%r{</li>}i, "\n")
    result.gsub!(%r{</?[uo]l[^>]*>}i, "\n")
    result.gsub!(%r{</?(p|div)[^>]*>}i, "\n")
    result.gsub!(%r{<strong[^>]*>(.*?)</strong>}im, '*\1*')
    result.gsub!(%r{<b[^>]*>(.*?)</b>}im, '*\1*')
    result.gsub!(%r{<em[^>]*>(.*?)</em>}im, '_\1_')
    result.gsub!(%r{<i[^>]*>(.*?)</i>}im, '_\1_')
    result.gsub!(%r{<code[^>]*>(.*?)</code>}im, '`\1`')
    result.gsub!(%r{<s[^>]*>(.*?)</s>}im, '~\1~')
    result.gsub!(%r{<strike[^>]*>(.*?)</strike>}im, '~\1~')
    result.gsub!(%r{<del[^>]*>(.*?)</del>}im, '~\1~')
    result = ActionController::Base.helpers.strip_tags(result)
    result.gsub!(/[ \t]+/, ' ')
    result.gsub!(/\n{3,}/, "\n\n")
    result.strip
  end

  def create_payload(type, message_content, action)
    {
      'type': type,
      'body': {
        'text': message_content
      },
      'action': action
    }
  end

  def create_payload_based_on_items(message)
    if message.content_attributes['items'].length <= 3
      create_button_payload(message)
    else
      create_list_payload(message)
    end
  end

  def interactive_body_text(message)
    content = html_to_whatsapp(message.content.to_s)
    return content if content.blank?

    lines = content.split("\n")
    removed_any = false

    while lines.any? && lines.last.strip.match?(/^\d+\.\s+\S/)
      lines.pop
      removed_any = true
    end

    pruned = lines.join("\n").strip
    return content unless removed_any
    pruned.presence || content
  end

  def create_button_payload(message)
    buttons = create_buttons(message.content_attributes['items'])
    json_hash = { 'buttons' => buttons }
    create_payload('button', interactive_body_text(message), JSON.generate(json_hash))
  end

  def create_list_payload(message)
    rows = create_rows(message.content_attributes['items'])
    section1 = { 'rows' => rows }
    sections = [section1]
    json_hash = { :button => 'Choose an item', 'sections' => sections }
    create_payload('list', interactive_body_text(message), JSON.generate(json_hash))
  end
end
