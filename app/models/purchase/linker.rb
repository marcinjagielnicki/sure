# Links a purchase to the transaction that paid for it and classifies that transaction by what
# was bought: one category is set and locked, several split the transaction. A transaction the
# user already split or categorized by hand is linked without being changed.
class Purchase::Linker
  def initialize(purchase)
    @purchase = purchase
  end

  def link!(entry, manual: false)
    transaction = entry.entryable
    raise Purchase::LinkError, "Only transactions can be linked" unless transaction.is_a?(Transaction)
    raise Purchase::LinkError, "The account can't be changed by this user" unless annotatable?(entry)

    Purchase.transaction do
      purchase.lock!
      existing = Purchase.where(transaction_id: transaction.id).where.not(id: purchase.id)
      raise Purchase::LinkError, "The transaction already belongs to another purchase" if existing.exists?

      purchase.update!(
        linked_transaction: transaction,
        status: :matched,
        matched_at: Time.current,
        match_candidate_entry_ids: []
      )
      transaction.update!(extra: transaction.extra.merge("purchase" => summary))

      if (reason = mismatch_reason(entry))
        purchase.flag!(reason, entry_id: entry.id) if manual
      else
        categorize(entry)
      end
    end
  end

  def unlink!
    Purchase.transaction do
      purchase.lock!
      transaction = purchase.linked_transaction
      if transaction
        transaction.update!(extra: transaction.extra.except("purchase"))
        rejected = purchase.rejected_entry_ids | [ transaction.entry.id ]
      end

      purchase.update!(
        linked_transaction: nil,
        matched_at: nil,
        rejected_entry_ids: rejected || purchase.rejected_entry_ids,
        status: purchase.email? ? :awaiting_payment : :unmatched
      )
    end
  end

  private
    attr_reader :purchase

    def annotatable?(entry)
      Account.annotatable_by(purchase.user).where(id: entry.account_id, family_id: purchase.family_id).exists?
    end

    def summary
      { "purchase_id" => purchase.id, "merchant" => purchase.merchant, "order_number" => purchase.order_number }
    end

    # Why the purchase's items can't be applied to this entry, or nil when they can.
    def mismatch_reason(entry)
      transaction = entry.entryable
      if purchase.total.nil? || entry.amount != purchase.total || entry.currency != purchase.currency
        :amount_differs
      elsif transaction.pending?
        :pending
      elsif transaction.transfer?
        :transfer
      end
    end

    def categorize(entry)
      transaction = entry.entryable
      return if entry.split_parent? || entry.split_child? || transaction.locked?(:category_id)

      groups = Purchase::CategoryAllocator.new(total: purchase.total, items: allocator_items, categories: purchase.family.categories).groups
      if groups.one?
        category = groups.first[:category]
        return unless category

        transaction.update!(category:)
        transaction.lock_attr!(:category_id)
      elsif groups.many?
        entry.split_once!(groups.map { |group| split_for(group) }, lock_attributes: true)
      end
    end

    def allocator_items
      purchase.items.includes(:category).map do |item|
        { "name" => item.name, "amount" => item.amount.to_s, "category_name" => item.category&.name }
      end
    end

    def split_for(group)
      label = group[:category]&.name || I18n.t("purchases.uncategorized_split_name")
      { name: [ purchase.merchant, label ].compact.join(" — "), amount: group[:amount], category_id: group[:category]&.id }
    end
end
