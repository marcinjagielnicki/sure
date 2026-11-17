# Turns a forwarded order email into a purchase: reads it with the routed AI model, records the
# order and its items, rejects emails that aren't orders or repeat one already recorded, looks for
# the payment, and tells the user what happened. The AI call runs with no database transaction
# open; results are written under the purchase's lock. Failures end the purchase as failed rather
# than retrying a paid AI call.
class Purchase::EmailProcessor
  def initialize(purchase)
    @purchase = purchase
  end

  def process!
    purchase.reload
    return unless purchase.processing?

    unless Ai.availability(:extract_purchase, family:, user: purchase.user).available? && provider
      return record_failure(StandardError.new("AI is not available for order emails"))
    end

    mail = Mail.new(purchase.original_email.download)
    @email_text = Purchase::EmailText.new(mail).call
    @subject = mail.subject

    response = provider.extract_purchase(text: email_text.text, files: email_text.files, category_names: family.categories.pluck(:name), family:)
    return record_failure(response.error) unless response.success?

    @extraction = response.data
    outcome = purchase.with_lock do
      next unless purchase.processing?

      apply_extraction
    end
    return unless outcome

    match if outcome == :processed
    notify(outcome)
  rescue StandardError => e
    record_failure(e)
  end

  private
    attr_reader :purchase, :extraction, :email_text, :subject

    def family = purchase.family

    def provider
      @provider ||= Provider::Registry.preferred_llm_provider.then do |candidate|
        candidate if candidate&.supports_purchase_extraction?
      end
    end

    # @return [Symbol] the email to send
    def apply_extraction
      problems = Purchase::Validator.new(extraction, family:).problems
      purchase.update!(ai_metadata: ai_metadata(problems))

      unless extraction.is_order
        purchase.update!(status: :rejected)
        purchase.flag!(:not_an_order)
        return :rejected
      end

      record_order(problems)
      if (existing = duplicate_of)
        purchase.update!(status: :rejected)
        purchase.flag!(:duplicate, purchase_id: existing.id)
        return :rejected
      end

      keep_receipt_files
      # A cash payment never shows up in a bank account: the user links or adds it by hand.
      if purchase.paid_by_cash?
        purchase.update!(status: :unmatched, match_deadline_on: nil)
      else
        purchase.update!(status: :awaiting_payment, match_deadline_on: extraction.order_date&.+(Purchase::DEADLINE_DAYS))
      end
      :processed
    end

    # Runs after what was read is saved, so a failure here (e.g. two jobs linking the same entry
    # at once) only costs this attempt: the purchase waits and Purchase::MatchPendingJob retries.
    def match
      purchase.with_lock { purchase.apply_match! if purchase.awaiting_payment? }
    rescue StandardError => e
      purchase.reload
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "warn",
        message: "Matching a new purchase failed: #{e.message}",
        source: self.class.name,
        family:,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: e.class.name }
      )
    end

    def record_order(problems)
      purchase.update!(
        merchant: extraction.merchant,
        order_number: extraction.order_number,
        ordered_on: extraction.order_date,
        total: extraction.total,
        currency: extraction.currency,
        shipping_cost: extraction.shipping_cost,
        payment_method: extraction.payment_method,
        merchant_domain: purchase.shop_domain(email_text.original_from_domain)
      )
      problems.each { |problem| purchase.flag!(problem["reason"], **problem.except("reason").symbolize_keys) }

      categories = family.categories.index_by { _1.name.downcase }
      purchase.items.delete_all
      Array(extraction.items).each_with_index do |item, position|
        purchase.items.create!(
          name: item["name"].presence || "?",
          quantity: decimal(item["quantity"]),
          unit_price: decimal(item["unit_price"]),
          amount: decimal(item["amount"]),
          category: categories[item["category_name"].to_s.downcase],
          seller: item["seller"].presence,
          position:
        )
      end
    end

    def keep_receipt_files
      purchase.receipt_files.purge
      receipt_file_numbers.each do |number|
        file = email_text.files[number - 1]
        purchase.receipt_files.attach(io: StringIO.new(file[:data]), filename: file[:filename], content_type: file[:content_type])
      end
    end

    def receipt_file_numbers
      Array(extraction.receipt_files)
    end

    # Another email purchase of this family for the same shop and order number. Checked under the
    # family's lock so two copies processed at once can't both pass.
    def duplicate_of
      return if purchase.order_number.blank?

      family.lock!
      family.purchases.email
        .where.not(id: purchase.id)
        .where.not(status: %w[rejected failed])
        .where("lower(merchant) = lower(?) AND lower(order_number) = lower(?)", purchase.merchant.to_s, purchase.order_number)
        .order(:created_at)
        .first
    end

    def ai_metadata(problems)
      {
        "provider" => provider.class.name.demodulize.underscore,
        "model" => provider.try(:default_model),
        "prompt_version" => Provider::Anthropic::PurchaseExtractor::PROMPT_VERSION,
        "extracted_at" => Time.current.iso8601,
        "subject" => subject,
        "raw_output" => extraction.to_h.as_json,
        "validation" => problems,
        "input_chars" => email_text.input_chars,
        "truncated" => email_text.truncated,
        "files" => email_text.files.each_with_index.map do |file, index|
          { "filename" => file[:filename], "content_type" => file[:content_type], "bytes" => file[:data].bytesize,
            "receipt" => receipt_file_numbers.include?(index + 1) }
        end
      }
    end

    def notify(outcome)
      PurchaseMailer.with(purchase:).public_send(outcome).deliver_later
    end

    def record_failure(error)
      purchase.reload.update!(status: :failed, error: error&.message)
      DebugLogEntry.capture(
        category: "ai",
        level: "error",
        message: "Order email extraction failed: #{error&.message}",
        source: self.class.name,
        family:,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: error&.class&.name }
      )
      PurchaseMailer.with(purchase:).failed.deliver_later
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
