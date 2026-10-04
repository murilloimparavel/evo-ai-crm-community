# frozen_string_literal: true

# Whatsapp::PhoneNumberNormalizer
#
# Single source of truth for normalizing a phone number into the canonical form
# WhatsApp itself resolves to. This is a faithful port of Evolution API's
# `createJid` logic (evolution-api/src/utils/createJid.ts) — the same rules the
# gateway applies before talking to WhatsApp — so that contacts created in the
# CRM (leads API, widget, import) and contacts seen via inbound WhatsApp messages
# converge on ONE string and stop duplicating.
#
# Covers the three countries with an "extra digit" quirk:
#   - Brazil (+55):  the nono dígito. Kept for DDD <= 30 (or landline-leading
#                    numbers); stripped for DDD >= 31 mobiles.
#   - Mexico (+52):  the leading "1" after the country code on 13-digit numbers.
#   - Argentina (+54): the leading "9" after the country code on 13-digit numbers.
#
# Returns DIGITS ONLY (no '+', no '@s.whatsapp.net'). Callers that persist E.164
# prepend '+' themselves; callers that build a JID append the suffix.
#
# Numbers from any other country, group JIDs, or strings that don't match the
# expected shape are returned with only cosmetic cleanup (non-digits removed),
# i.e. the function is a safe pass-through — never raises.
class Whatsapp::PhoneNumberNormalizer
  def self.call(raw)
    new(raw).call
  end

  # Convenience for lookup/persist paths that store E.164 ('+<digits>'). Returns
  # nil for blank/uninormalizable input so callers can guard a find_by cleanly.
  def self.to_e164(raw)
    digits = call(raw)
    return nil if digits.blank?

    "+#{digits}"
  end

  # Returns an array of search query substrings for flexible matching of Brazilian
  # phone numbers. For example, given "61993578880", "5561993578880", "6193578880"
  # or "+55 (61) 99357-8880", returns:
  #   ["556193578880", "5561993578880", "6193578880", "61993578880"]
  # If the input is not a Brazilian mobile number shape, returns [clean_digits].
  def self.search_variants(raw)
    digits = raw.to_s.gsub(/\D/, '')
    return [] if digits.empty?

    variants = [digits]

    # Normalize to DDD + subscriber if national (10 or 11 digits) or international (12 or 13 digits)
    if digits.start_with?('55') && digits.length.between?(12, 13)
      ddd = digits[2, 2]
      subscriber = digits[4..]
      prefix = '55'
    elsif !digits.start_with?('55') && digits.length.between?(10, 11)
      ddd = digits[0, 2]
      subscriber = digits[2..]
      prefix = ''
    else
      return variants
    end

    # Build both 8-digit and 9-digit versions of the subscriber
    if subscriber.length == 9 && subscriber.start_with?('9')
      sub_with_9 = subscriber
      sub_without_9 = subscriber[1..]
    elsif subscriber.length == 8
      sub_without_9 = subscriber
      sub_with_9 = "9#{subscriber}"
    else
      return variants
    end

    # Add all useful permutations (with 55, without 55, with +, without +)
    variants << "55#{ddd}#{sub_with_9}"
    variants << "55#{ddd}#{sub_without_9}"
    variants << "+55#{ddd}#{sub_with_9}"
    variants << "+55#{ddd}#{sub_without_9}"
    variants << "#{ddd}#{sub_with_9}"
    variants << "#{ddd}#{sub_without_9}"

    variants.uniq
  end

  def initialize(raw)
    @raw = raw.to_s
  end

  # @return [String, nil] digits-only normalized number, or nil for blank input.
  def call
    return nil if @raw.strip.empty?

    number = strip_to_digits(@raw)
    return number if number.empty?

    number = format_mx_or_ar(number)
    format_br(number)
  end

  private

  # Mirrors createJid's cleanup: drop whitespace, '+', parens, ':' suffix and any
  # JID domain, then keep only digits.
  def strip_to_digits(value)
    value.gsub(/\s/, '')
         .delete('+()')
         .split(':').first.to_s
         .split('@').first.to_s
         .gsub(/\D/, '')
  end

  # Port of formatMXOrARNumber: for MX (52) / AR (54), a 13-digit number carries
  # an extra leading digit right after the country code — drop it.
  def format_mx_or_ar(number)
    country_code = number[0, 2]
    return number unless %w[52 54].include?(country_code)
    return number unless number.length == 13

    country_code + number[3..]
  end

  # Port of formatBRNumber: regex ^(dd)(dd)\d(\d{8})$ — country, DDD, the nono
  # dígito (NOT captured), and the 8-digit subscriber number.
  #   keep the 9 when leading subscriber digit < 7 OR DDD < 31
  #   otherwise strip the 9
  def format_br(number)
    match = /\A(\d{2})(\d{2})\d(\d{8})\z/.match(number)
    return number unless match

    country, ddd, subscriber = match[1], match[2], match[3]
    return number unless country == '55'

    joker = subscriber[0].to_i
    return match[0] if joker < 7 || ddd.to_i < 31

    country + ddd + subscriber
  end
end
