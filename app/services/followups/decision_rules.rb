# frozen_string_literal: true

module Followups
  # A bounded typed expression language. No callable names, paths, SQL or eval.
  class DecisionRules
    class Invalid < StandardError; end
    ACTIONS = %w[send block abstain].freeze

    def initialize(conditions:, questions:)
      @conditions = conditions
      @questions = questions
      @nodes = 0
      validate!
    end

    def call(answers)
      # Conservative precedence prevents an earlier SEND from bypassing BLOCK.
      matched = @conditions.select { |rule| evaluate(rule.fetch('when'), answers) }
      rule = matched.find { |item| item['action'] == 'block' } ||
             matched.find { |item| item['action'] == 'abstain' } ||
             matched.find { |item| item['action'] == 'send' }
      return { action: 'abstain', reason: 'no_matching_condition', template_id: nil } unless rule

      { action: rule['action'], reason: rule['reason'], template_id: rule['template_id'] }
    end

    private

    def validate!
      invalid! unless @conditions.is_a?(Array) && @conditions.size.between?(1, 16)
      @conditions.each do |rule|
        invalid! unless rule.is_a?(Hash) && (rule.keys - %w[action reason template_id when]).empty?
        invalid! unless ACTIONS.include?(rule['action']) && rule['reason'].is_a?(String) && /\A[a-z][a-z0-9_]{0,79}\z/.match?(rule['reason'])
        invalid! if rule['action'] == 'send' && !rule['template_id'].is_a?(String)
        validate_node!(rule['when'], 0)
      end
    end

    def validate_node!(node, depth)
      @nodes += 1
      invalid! unless node.is_a?(Hash) && depth <= 4 && @nodes <= 64
      if node.keys == ['all'] || node.keys == ['any']
        children = node.values.first
        invalid! unless children.is_a?(Array) && children.size.between?(1, 16)
        children.each { |child| validate_node!(child, depth + 1) }
        return
      end
      invalid! unless node.keys.sort == %w[field op question value]
      question = @questions[node['question']]
      invalid! unless question.is_a?(Hash) && %w[eq in gte lte].include?(node['op'])
      string_field = question['type'] == 'choice' && node['field'] == 'choice'
      score_field = question['type'] == 'score' && node['field'] == 'score'
      number_field = (%w[choice score].include?(question['type']) && node['field'] == 'confidence') ||
                     (question['type'] == 'noul' && node['field'] == 'noul') || score_field
      invalid! unless string_field || number_field
      values = node['op'] == 'in' ? node['value'] : [node['value']]
      invalid! unless values.is_a?(Array) && values.size.between?(1, 32)
      invalid! if string_field && !%w[eq in].include?(node['op'])
      values.each do |value|
        valid = if string_field
                  question['criteria'].key?(value)
                elsif score_field
                  value.is_a?(Numeric) && value.finite? && value.between?(0, question['criteria'].length - 1)
                else
                  QuestionValidator.probability?(value)
                end
        invalid! unless valid
      end
    end

    def evaluate(node, answers)
      return node['all'].all? { |child| evaluate(child, answers) } if node.key?('all')
      return node['any'].any? { |child| evaluate(child, answers) } if node.key?('any')

      actual = answers.fetch(node['question']).fetch(node['field'])
      expected = node['value']
      case node['op']
      when 'eq' then actual == expected
      when 'in' then expected.include?(actual)
      when 'gte' then actual >= expected
      when 'lte' then actual <= expected
      end
    end

    def invalid!
      raise Invalid, 'invalid_decision_conditions'
    end
  end
end
