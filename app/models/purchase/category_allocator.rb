# Groups a purchase's line items (from a receipt or an order email) by the category the model
# assigned them, into amounts that add up exactly to the total, ready to become the parts of a
# split transaction. Whatever the total holds beyond the items (shipping, a basket discount) is
# spread across the groups in proportion to their items.
class Purchase::CategoryAllocator
  # Groups smaller than this share of the total join the largest group, so a carrier bag doesn't
  # become its own split.
  FOLD_SHARE = BigDecimal("0.05")

  # @param items [Array<Hash>] string keys "name", "amount", optional "discount", "category_name"
  def initialize(total:, items:, categories:)
    @total = total
    @items = Array(items)
    @categories_by_name = categories.index_by { |category| category.name.downcase }
  end

  # @return [Array<Hash>] { category: Category|nil, amount: BigDecimal, item_names: [String] },
  #   largest first, amounts summing to the total
  def groups
    return [] if total.nil?

    nets = items.map { |item| [ item, decimal(item["amount"]) - decimal(item["discount"]) ] }
    items_total = nets.sum { |_, net| net }
    return [ group(nil, total, []) ] unless items_total.positive?

    grouped = nets.group_by { |item, _| category_for(item["category_name"]) }.map do |category, rows|
      group(category, rows.sum { |_, net| net * total / items_total }.round(2), rows.map { |item, _| item["name"] })
    end

    grouped = fold_small(grouped.sort_by { -_1[:amount] })
    grouped.first[:amount] += total - grouped.sum { _1[:amount] }
    grouped
  end

  private
    attr_reader :total, :items, :categories_by_name

    def category_for(name)
      categories_by_name[name.to_s.downcase] if name.present?
    end

    def fold_small(groups)
      largest, *rest = groups
      kept = rest.reject do |candidate|
        next false if candidate[:amount] >= FOLD_SHARE * total

        largest[:amount] += candidate[:amount]
        largest[:item_names] += candidate[:item_names]
        true
      end
      [ largest, *kept ]
    end

    def group(category, amount, item_names)
      { category:, amount:, item_names: }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
