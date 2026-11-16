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
