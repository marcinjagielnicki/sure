# Looks for the bank's version of a receipt's payment on the account the user picked, for the
# case where bank data arrived before the photo. Name is deliberately ignored: receipt merchant
# names and bank descriptions rarely agree.
class ReceiptScan::Matcher
  Result = Data.define(:kind, :entries)

  TRANSACTIONS_JOIN = "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'".freeze

  def initialize(scan, extraction)
    @scan = scan
    @extraction = extraction
  end

  # kind is :skip (this receipt is never matched), :none, :single, :ambiguous or
  # :duplicate_receipt (another receipt on the account already records this payment)
  def result
    return Result.new(kind: :skip, entries: []) if skip?

    earlier_receipt = same_payment.where(date: extraction.date).merge(receipt_entries).first
    return Result.new(kind: :duplicate_receipt, entries: [ earlier_receipt ]) if earlier_receipt

    candidates = bank_candidates.to_a
    kind = case candidates.size
    when 0 then :none
    when 1 then :single
    else :ambiguous
    end
    Result.new(kind:, entries: candidates)
  end

  private
    attr_reader :scan, :extraction

    def skip?
      extraction.document_kind != "receipt" ||
        extraction.payment_method == "cash" ||
        extraction.currency != scan.account.currency ||
        extraction.total.nil? || !extraction.total.positive? ||
        extraction.date.nil?
    end

    def same_payment
      scope = scan.account.entries
        .joins(TRANSACTIONS_JOIN)
        .where(amount: extraction.total, currency: extraction.currency, parent_entry_id: nil)
      placeholder_entry_id = scan.linked_transaction&.entry&.id
      placeholder_entry_id ? scope.where.not(id: placeholder_entry_id) : scope
    end

    def receipt_entries
      Entry.where("transactions.extra ? 'receipt'")
    end

    def bank_candidates
      window = ReceiptScan::MATCH_DATE_WINDOW.days

      same_payment
        .where(date: (extraction.date - window)..(extraction.date + window))
        .where.not("transactions.extra ? 'receipt'")
        .where.not(id: Entry.where.not(parent_entry_id: nil).select(:parent_entry_id))
        .where.not(Transaction.pending_sql)
        .order(:date, :created_at)
    end
end
