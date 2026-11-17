# Keeps the purchase of a receipt scan in step with what was read from the receipt. The receipt
# processor has already put the scan on its final transaction and categorized it, so the purchase
# only records that link and the items.
class Purchase::FromReceiptScan
  PAYMENT_METHODS = { "card" => "card", "cash" => "other", "mixed" => "other" }.freeze

  # @param extraction_hash [Hash] a ReceiptExtraction as JSON (string keys)
  def self.sync!(scan, extraction_hash:, ai_metadata:)
    new(scan, extraction_hash, ai_metadata).sync!
  end

  def initialize(scan, extraction_hash, ai_metadata)
    @scan = scan
    @extraction = extraction_hash.to_h.stringify_keys
    @ai_metadata = ai_metadata
  end

  def sync!
    purchase = Purchase.find_or_initialize_by(receipt_scan_id: scan.id)
    Purchase.transaction do
      purchase.update!(
        family: scan.family,
        user: scan.user,
        source: :receipt,
        linked_transaction: scan.linked_transaction,
        status: scan.linked_transaction ? :matched : :unmatched,
        matched_at: scan.linked_transaction ? (purchase.matched_at || Time.current) : nil,
        merchant: extraction["merchant"],
        ordered_on: extraction["date"].presence || scan.linked_transaction&.entry&.date,
        total: extraction["total"],
        currency: extraction["currency"].presence || scan.account.currency,
        payment_method: PAYMENT_METHODS.fetch(extraction["payment_method"].to_s, "unknown"),
        review_reasons: scan.review_reasons,
        ai_metadata:
      )
      replace_items(purchase)
    end
    purchase
  end

  private
    attr_reader :scan, :extraction, :ai_metadata

    def replace_items(purchase)
      categories = scan.family.categories.index_by { _1.name.downcase }
      purchase.items.delete_all
      Array(extraction["line_items"]).each_with_index do |item, position|
        purchase.items.create!(
          name: item["name"].presence || "?",
          quantity: decimal(item["quantity"]),
          amount: decimal(item["amount"]).to_d - decimal(item["discount"]).to_d,
          category: categories[item["category_name"].to_s.downcase],
          position:
        )
      end
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
