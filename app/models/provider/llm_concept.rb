module Provider::LlmConcept
  extend ActiveSupport::Concern

  # Items per LLM call for AI rule jobs and evals: ENV > Setting > 25.
  def self.max_items_per_call
    [ ENV["LLM_MAX_ITEMS_PER_CALL"], Setting.llm_max_items_per_call, 25 ].map(&:to_i).find(&:positive?)
  end

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  EnhancedMerchant = Data.define(:merchant_id, :business_url)

  def enhance_provider_merchants(merchants)
    raise NotImplementedError, "Subclasses must implement #enhance_provider_merchants"
  end

  # One proposed recurring-bill configuration, inferred from charge history.
  # Every field is nullable: null means the history cannot support a value
  # (or, in configure mode, that the current configuration is already right).
  BillSetupSuggestion = Data.define(
    :name, :amount, :frequency, :day_of_month, :weekday, :month_of_year,
    :category_name, :bill_type, :autopay, :confidence, :rationale
  )

  def suggest_bill_setup(charges:, categories: [], current_config: nil, model: "", family: nil)
    raise NotImplementedError, "Subclasses must implement #suggest_bill_setup"
  end

  PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data)

  def supports_pdf_processing?
    false
  end

  def process_pdf(pdf_content:, family: nil)
    raise NotImplementedError, "Provider does not support PDF processing"
  end

  ReceiptExtraction = Data.define(
    :document_kind, :merchant, :nip, :date, :due_date, :total, :currency, :payment_method,
    :vat_breakdown, :line_items, :confidence, :raw_text
  )

  def supports_receipt_extraction?(model: nil)
    false
  end

  PurchaseExtraction = Data.define(
    :is_order, :not_order_reason, :merchant, :order_number, :order_date, :currency, :total,
    :shipping_cost, :discount_total, :payment_method, :items, :confidence, :notes, :receipt_files
  )

  def supports_purchase_extraction?(model: nil)
    false
  end

  # files: attachments sent along ({data:, content_type:, filename:}); the extraction's
  # receipt_files are the 1-based numbers of those that are the purchase's receipt or invoice.
  def extract_purchase(text:, category_names:, files: [], model: "", family: nil)
    raise NotImplementedError, "Provider does not support purchase extraction"
  end

  def extract_receipt(files:, category_names:, model: "", family: nil)
    raise NotImplementedError, "Provider does not support receipt extraction"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data, :usage)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args, :extra_content) do
    def initialize(id:, call_id:, function_name:, function_args:, extra_content: nil)
      super
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end
