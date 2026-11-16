# Turns a processing ReceiptScan into a finished transaction: reads the receipt with the routed
# AI model, checks the result, attaches it to the bank's version of the payment when that is
# already here, otherwise fills in the placeholder, and splits the spend by category.
class ReceiptScan::Processor
  # Problems that make the extracted payment unreliable enough not to merge into a bank entry.
  BLOCKING_PROBLEMS = %w[missing_total non_positive_total missing_date currency_mismatch unknown_currency].freeze

  def initialize(scan)
    @scan = scan
  end

  def process!
    scan.with_lock do
      return unless scan.processing?

      run
    end
  end

  private
    attr_reader :scan, :extraction, :problems

    def family = scan.family

    def run
      @placeholder = scan.linked_transaction
      unless Ai.availability(:extract_receipt, family:, user: scan.user).available? && provider
        scan.flag!(:ai_unavailable)
        return write_receipt_extra(placeholder)
      end

      @extraction = extract
      return unless extraction

      @problems = ReceiptScan::Validator.new(extraction, account: scan.account).problems
      problems.each { |problem| scan.flag!(problem["reason"], **problem.except("reason").symbolize_keys) }

      transaction = resolve_transaction
      fill(transaction) if transaction == placeholder
      categorize(transaction.entry)

      scan.update!(status: :completed) if scan.processing?
      write_receipt_extra(transaction)
    end

    def provider
      @provider ||= Provider::Registry.preferred_llm_provider.then do |candidate|
        candidate if candidate&.supports_receipt_extraction?
      end
    end

    def extract
      response = provider.extract_receipt(
        files: scan.files.map { |file| { data: file.download, content_type: file.content_type } },
        category_names: family.categories.pluck(:name),
        family:
      )
      return response.data if response.success?

      record_failure(response.error)
      nil
    end

    def record_failure(error)
      scan.update!(status: :failed, error: error&.message)
      write_receipt_extra(placeholder)
      DebugLogEntry.capture(
        category: "ai",
        level: "error",
        message: "Receipt extraction failed: #{error&.message}",
        source: self.class.name,
        family:,
        account: scan.account,
        user: scan.user,
        metadata: { receipt_scan_id: scan.id, error_class: error&.class&.name }
      )
    end

    attr_reader :placeholder

    # The transaction this receipt ends up on: the bank's, when exactly one bank entry is this
    # payment, otherwise the placeholder.
    def resolve_transaction
      return placeholder if (problems.map { _1["reason"] } & BLOCKING_PROBLEMS).any?

      match = ReceiptScan::Matcher.new(scan, extraction).result
      case match.kind
      when :single
        merge_into(match.entries.first.entryable)
      when :ambiguous
        scan.flag!(:possible_duplicates, entry_ids: match.entries.map(&:id))
        placeholder
      when :duplicate_receipt
        scan.flag!(:duplicate_receipt, entry_id: match.entries.first.id)
        placeholder
      else
        placeholder
      end
    end

    def merge_into(bank_transaction)
      if bank_transaction.attachments.count + scan.files.count > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        scan.flag!(:too_many_attachments, entry_id: bank_transaction.entry.id)
        return placeholder
      end

      bank_transaction.attachments.attach(scan.files.blobs)
      scan.update!(linked_transaction: bank_transaction)
      placeholder.attachments.detach
      placeholder.entry.destroy!
      bank_transaction
    end

    def fill(transaction)
      entry = transaction.entry
      entry.update!(
        name: extraction.merchant.presence || I18n.t("receipt_scans.fallback_name"),
        date: extraction.date || entry.date,
        amount: extraction.total || entry.amount,
        currency: extraction.currency.presence || entry.currency
      )
      entry.lock_saved_attributes!
      entry.sync_account_later
    end

    def categorize(entry)
      return if extraction.total.nil? || entry.amount != extraction.total

      groups = ReceiptScan::CategoryAllocator.new(extraction, categories: family.categories).groups
      if groups.one?
        entry.entryable.update!(category: groups.first[:category]) if groups.first[:category]
      elsif groups.many?
        entry.split_once!(groups.map { |group| split_for(group) }, lock_attributes: true)
      end
    end

    def split_for(group)
      label = group[:category]&.name || I18n.t("receipt_scans.uncategorized_split_name")
      { name: [ extraction.merchant, label ].compact.join(" — "), amount: group[:amount], category_id: group[:category]&.id }
    end

    def write_receipt_extra(transaction)
      return unless transaction

      receipt = (transaction.extra["receipt"] || {}).merge(
        "scan_id" => scan.id,
        "status" => scan.completed? ? "completed" : (scan.processing? ? "processing" : "needs_review"),
        "review_reasons" => scan.review_reasons
      )
      receipt.merge!(extraction.to_h.as_json) if extraction
      transaction.update!(extra: transaction.extra.merge("receipt" => receipt))
    end
end
