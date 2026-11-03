# frozen_string_literal: true

require 'json'

module Followups
  # Policy data is compiled to the provider's small, closed question schema.
  class QuestionValidator
    class Invalid < StandardError; end
    MAX_QUESTIONS = 12
    MAX_BYTES = 12 * 1024
    QUESTION_TYPES = %w[choice noul score].freeze
    KEY = /\A[a-z][a-z0-9_]{0,63}\z/

    def self.probability?(value)
      value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end

    def self.call(questions)
      new.call(questions)
    end

    # Validate the complete bounded typed question contract before compiling any provider payload.
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def call(questions)
      invalid! unless questions.is_a?(Hash) && questions.size.between?(1, MAX_QUESTIONS)
      invalid! if JSON.generate(questions).bytesize > MAX_BYTES
      questions.each_with_object({}) do |(id, original), compiled|
        invalid! unless id.is_a?(String) && KEY.match?(id) && original.is_a?(Hash)
        question = original.stringify_keys
        invalid! unless (question.keys - %w[type instructions criteria min_confidence yes_threshold no_threshold]).empty?
        invalid! unless QUESTION_TYPES.include?(question['type'])
        description!(question['instructions'])
        criteria = question['criteria']
        if question['type'] == 'score'
          invalid! unless criteria.is_a?(Array) && criteria.size.between?(2, 10)
          criteria.each { |value| description!(value) }
        else
          invalid! unless criteria.is_a?(Hash)
          criteria.each do |key, value|
            invalid! unless key.is_a?(String)
            description!(value)
          end
        end
        if question['type'] == 'choice'
          invalid! unless criteria.size.between?(2, 32) && criteria.key?('unclear')
          invalid! unless criteria.keys.all? { |key| KEY.match?(key) }
          invalid! unless self.class.probability?(question['min_confidence'])
          invalid! if question.key?('yes_threshold') || question.key?('no_threshold')
        elsif question['type'] == 'noul'
          invalid! unless criteria.keys.sort == %w[false true]
          yes, no = question.values_at('yes_threshold', 'no_threshold')
          invalid! unless self.class.probability?(yes) && self.class.probability?(no) && no < yes
          invalid! if question.key?('min_confidence')
        else
          invalid! unless self.class.probability?(question['min_confidence'])
          invalid! if question.key?('yes_threshold') || question.key?('no_threshold')
        end
        compiled[id] = question.slice('type', 'instructions', 'criteria')
      end
    rescue JSON::GeneratorError, SystemStackError
      invalid!
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    private

    # Validate the complete bounded typed question contract before compiling any provider payload.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def description!(value, depth = 0)
      invalid! if depth > 4
      case value
      when String then invalid! if value.strip.empty? || !value.valid_encoding? || value.length > 2000
      when Hash
        invalid! if value.empty? || value.size > 16
        value.each do |key, item|
          invalid! unless key.is_a?(String)
          description!(item, depth + 1)
        end
      when Array
        invalid! if value.empty? || value.size > 16
        value.each { |item| description!(item, depth + 1) }
      else invalid!
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def invalid!
      raise Invalid, 'invalid_question_pack'
    end
  end
end
