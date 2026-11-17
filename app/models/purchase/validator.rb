# Checks an order read from an email for numbers and dates that don't add up. Problems are
# recorded for review; the purchase is still kept.
class Purchase::Validator
  TOLERANCE = BigDecimal("0.01")

  def initialize(extraction, family:)
    @extraction = extraction
    @family = family
  end

  # @return [Array<Hash>] each with a "reason" and optional details
  def problems
    [ total_problem, date_problem, currency_problem, items_problem, categories_problem ].compact
  end

  private
    attr_reader :extraction, :family

    def total_problem
      if extraction.total.nil?
        { "reason" => "missing_total" }
      elsif !extraction.total.positive?
        { "reason" => "non_positive_total" }
      end
    end

    def date_problem
      date = extraction.order_date
      if date.nil?
        { "reason" => "missing_date" }
      elsif date > Date.current
        { "reason" => "future_date", "date" => date.iso8601 }
      elsif date < Date.current - 1.year
        { "reason" => "too_old", "date" => date.iso8601 }
      end
    end

    def currency_problem
      { "reason" => "unknown_currency", "currency" => extraction.currency } unless known_currency?(extraction.currency)
    end

    def items_problem
      return if extraction.total.nil? || items.empty?

      expected = items.sum { decimal(_1["amount"]) } + decimal(extraction.shipping_cost) - decimal(extraction.discount_total)
      return if (expected - extraction.total).abs <= TOLERANCE

      { "reason" => "items_mismatch", "expected" => expected.to_s("F"), "actual" => extraction.total.to_s("F") }
    end

    def categories_problem
      known = family.categories.pluck(:name).map(&:downcase)
      unknown = items.filter_map { _1["category_name"].presence }.reject { known.include?(_1.downcase) }.uniq
      { "reason" => "unknown_categories", "names" => unknown } if unknown.any?
    end

    def items
      Array(extraction.items)
    end

    def known_currency?(code)
      code.present? && Money::Currency.new(code).present?
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
