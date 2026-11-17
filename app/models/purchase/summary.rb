# The numbers above the purchases list: what was spent this month, what still waits for a payment
# and the shop bought from most. Orders that weren't added or couldn't be read don't count as
# spending. Amounts aren't converted: other currencies are reported beside the family's own.
class Purchase::Summary
  NOT_SPENDING = %w[processing rejected failed].freeze

  Result = Data.define(:spent, :other_spent, :purchases_count, :items_count, :to_match_count, :top_merchant, :top_merchant_count)

  # @return [Hash{Date, nil => Array<Money>}] totals per month (nil for undated orders), the
  #   family's currency first
  def self.month_totals(scope, currency:)
    scope.unscope(:order, :includes).where.not(status: NOT_SPENDING).where.not(total: nil)
      .group(Arel.sql("date_trunc('month', purchases.ordered_on)::date"), :currency)
      .sum(:total)
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |((month, code), sum), totals| totals[month] << Money.new(sum, code.presence || currency) }
      .transform_values { |amounts| amounts.sort_by { [ _1.currency.iso_code == currency ? 0 : 1, _1.currency.iso_code ] } }
  end

  def initialize(scope, currency:, month: Date.current)
    @scope = scope.unscope(:order, :includes)
    @currency = currency
    @month = month
  end

  def call
    totals = self.class.month_totals(spending, currency:)[month.beginning_of_month] || []
    own, other = totals.partition { _1.currency.iso_code == currency }
    top_merchant, top_merchant_count = spending.where.not(merchant: [ nil, "" ]).group(:merchant).order(Arel.sql("COUNT(*) DESC"), :merchant).limit(1).count.first

    Result.new(
      spent: own.first || Money.new(0, currency),
      other_spent: other,
      purchases_count: spending.count,
      items_count: PurchaseItem.where(purchase_id: spending.select(:id)).count,
      to_match_count: scope.to_match.count,
      top_merchant:,
      top_merchant_count: top_merchant_count.to_i
    )
  end

  private
    attr_reader :scope, :currency, :month

    def spending
      @spending ||= scope.where(ordered_on: month.all_month).where.not(status: NOT_SPENDING)
    end
end
