# frozen_string_literal: true

module Followups
  class Classifier
    def initialize(client: Ai::JevClient.new)
      @client = client
    end

    # Keep schema verification, confidence checks and action precedence together in this closed decision contract.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def classify(snapshot:, policy:)
      @metadata = nil
      config = policy.fetch('classifier')
      @metadata = { model: config['model'], question_version: config['question_version'], input_tokens: 0,
                    usage_known: true, retryable: false, retry_after: nil }
      return result('abstain', 'unsupported_model') unless config['model'] == Ai::JevClient::MODEL
      return result('abstain', 'invalid_question_version') unless config['question_version'].is_a?(String) && config['question_version'].present?
      return result('abstain', snapshot[:reason] || 'invalid_snapshot') unless snapshot[:state].is_a?(Hash)
      return result('abstain', 'snapshot_expired') unless snapshot[:valid_until] && snapshot[:valid_until] > Time.current

      questions = QuestionValidator.call(config['questions'])
      rules = DecisionRules.new(conditions: config['conditions'], questions: config['questions'])
      if JSON.generate(model: config['model'], state: snapshot[:state], questions: questions).bytesize > Ai::JevClient::MAX_REQUEST_BYTES
        return result('abstain', 'snapshot_too_large')
      end

      response = @client.call(state: snapshot[:state], questions: questions, model: config['model'])
      @metadata.merge!(response.slice(:model, :input_tokens, :usage_known, :retryable, :retry_after))
      return result('abstain', response[:reason] || 'classifier_failed') unless response[:ok]

      answers = response.fetch(:answers)
      classification = answers.transform_values { |answer| answer.slice('type', 'choice', 'confidence', 'noul', 'score', 'probabilities') }
      uncertain = config['questions'].any? do |id, question|
        answer = answers.fetch(id)
        if question['type'] == 'noul'
          answer['noul'] > question['no_threshold'] && answer['noul'] < question['yes_threshold']
        else
          answer['choice'] == 'unclear' || answer['confidence'] < question['min_confidence']
        end
      end
      return result('abstain', 'uncertain_answer').merge(classification: classification, proposed_action: 'abstain') if uncertain

      decision = rules.call(answers)
      if snapshot[:classification_only] == true || snapshot.dig(:references, :classification_only) == true
        return result('abstain', 'observation_only').merge(classification: classification, proposed_action: decision[:action])
      end

      if decision[:action] == 'send'
        return result('abstain', 'approved_anchor_required') if snapshot.dig(:references, :anchor_message_id).blank?
        return result('abstain', 'template_not_approved') unless Templates.fetch(decision[:template_id])
      end
      decision.merge(@metadata).merge(classification: classification)
    rescue QuestionValidator::Invalid, DecisionRules::Invalid, KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
      result('abstain', 'invalid_classifier_configuration')
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    private

    def result(action, reason)
      { action: action, reason: reason, template_id: nil }.merge(@metadata || {
                                                                   model: nil, question_version: nil, input_tokens: 0,
                                                                   usage_known: true, retryable: false, retry_after: nil
                                                                 })
    end
  end
end
