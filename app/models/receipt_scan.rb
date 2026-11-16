# A receipt, bill or invoice a family member photographed or uploaded, and the state of turning
# it into a transaction on the account they picked.
class ReceiptScan < ApplicationRecord
  MAX_FILES = 5
  MAX_FILE_SIZE = 10.megabytes
  ACCEPTED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif application/pdf].freeze
  # Days either side of the receipt date in which a bank transaction counts as the same payment.
  MATCH_DATE_WINDOW = 3

  belongs_to :family
  belongs_to :account
  belongs_to :user
  # Not `:transaction`: that name would shadow ActiveRecord::Base#transaction.
  belongs_to :linked_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true

  has_many_attached :files

  enum :status, {
    processing: "processing",
    completed: "completed",
    needs_review: "needs_review",
    failed: "failed"
  }, validate: true

  validate :account_belongs_to_family

  InvalidUpload = Class.new(StandardError)

  class << self
    # Stores the normalized files and gives the user a "Processing receipt…" transaction on the
    # account right away; ReceiptScan::ProcessJob fills it in. The caller authorizes the account.
    def create_from_upload!(family:, user:, account:, uploads:)
      normalized = normalize_uploads!(Array(uploads).compact)

      scan = transaction do
        scan = create!(family:, user:, account:)
        normalized.each { |file| scan.files.attach(**file) }

        entry = account.entries.create!(
          name: I18n.t("receipt_scans.placeholder_name"),
          date: Date.current,
          amount: 0,
          currency: account.currency,
          entryable: Transaction.new(extra: { "receipt" => { "scan_id" => scan.id, "status" => "processing" } })
        )
        entry.entryable.attachments.attach(scan.files.blobs)
        scan.update!(linked_transaction: entry.entryable)
        scan
      end

      ReceiptScan::ProcessJob.perform_later(scan)
      scan
    end

    private
      def normalize_uploads!(uploads)
        raise InvalidUpload, I18n.t("receipt_scans.errors.no_files") if uploads.empty?
        raise InvalidUpload, I18n.t("receipt_scans.errors.too_many_files", count: MAX_FILES) if uploads.size > MAX_FILES

        uploads.map do |upload|
          if upload.size > MAX_FILE_SIZE
            raise InvalidUpload, I18n.t("receipt_scans.errors.too_large", size: MAX_FILE_SIZE / 1.megabyte)
          end

          ReceiptScan::ImageNormalizer.call(io: upload, content_type: upload.content_type, filename: upload.original_filename)
        rescue ReceiptScan::ImageNormalizer::UnsupportedFile
          raise InvalidUpload, I18n.t("receipt_scans.errors.unsupported_file", filename: upload.original_filename)
        end
      end
  end

  def flag!(reason_key, **details)
    update!(
      status: :needs_review,
      review_reasons: review_reasons + [ { "reason" => reason_key.to_s, **details.deep_stringify_keys } ]
    )
  end

  private
    def account_belongs_to_family
      return if account.nil? || family.nil?

      errors.add(:account, :invalid) unless account.family_id == family_id
    end
end
