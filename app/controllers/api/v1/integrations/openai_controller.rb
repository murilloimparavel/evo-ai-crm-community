class Api::V1::Integrations::OpenaiController < Api::V1::BaseController
  require_permissions({
    process_event: 'integrations.execute'
  })

  def process_event
    # Use global configuration instead of hook settings
    processor = Integrations::Openai::GlobalProcessorService.new(
      account: nil,
      event: permitted_event_params
    )

    result = processor.perform

    if result.is_a?(Hash) && result[:error].present?
      message = provider_error_message(result[:error], result[:error_code])
      return render json: { error: message }, status: :bad_gateway
    end

    if result.present?
      render json: result
    else
      render json: { error: 'Unable to process request' }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "OpenAI Global Processing Error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def provider_error_message(error, error_code)
    payload = error.is_a?(Hash) ? error : {}
    nested = payload['error'] || payload[:error]
    detail = if nested.is_a?(Hash)
               nested['message'] || nested[:message]
             elsif nested.is_a?(String)
               nested
             end
    detail ||= payload['message'] || payload[:message]
    return detail if detail.present?

    error_code.present? ? "Falha do provedor de IA (HTTP #{error_code})." : 'O provedor de IA recusou a solicitação.'
  end

  def permitted_event_params
    params.require(:event).permit(:name, data: {})
  end
end
