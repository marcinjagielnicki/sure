# Keeps looking for the payment of forwarded orders: links one that has shown up since, refreshes
# the candidates of ambiguous ones, and tells the user once when an order passes its deadline
# unpaid. Unmatched orders keep being tried until MATCH_HORIZON_DAYS, for statements imported
# weeks later.
class Purchase::MatchPendingJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Purchase.email.to_match
      .where(ordered_on: (Date.current - Purchase::MATCH_HORIZON_DAYS)..)
      .find_each { |purchase| process(purchase) }
  end

  private
    def process(purchase)
      outcome = purchase.with_lock do
        next unless purchase.status.in?(Purchase::OPEN_STATUSES)

        purchase.apply_match!
        if purchase.matched?
          :matched
        elsif purchase.awaiting_payment? && overdue?(purchase)
          purchase.update!(status: :unmatched, unmatched_notified_at: Time.current)
          :unmatched
        end
      end
      PurchaseMailer.with(purchase:).public_send(outcome).deliver_later if outcome
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "error",
        message: "Matching a purchase failed: #{e.message}",
        source: self.class.name,
        family: purchase.family,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: e.class.name }
      )
    end

    def overdue?(purchase)
      purchase.unmatched_notified_at.nil? && purchase.match_deadline_on.present? && purchase.match_deadline_on < Date.current
    end
end
