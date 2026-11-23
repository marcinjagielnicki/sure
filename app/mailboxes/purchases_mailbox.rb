# Receives forwarded order emails from the order mailbox. Only email from a configured sender or
# plus tag, passing sender authentication, from a user with preview features on, becomes a
# purchase; everything else is bounced without a reply and logged for the settings page.
class PurchasesMailbox < ApplicationMailbox
  def process
    resolver = PurchaseInbox::SenderResolver.new(mail)
    result = resolver.result
    return reject!(result.reason, from: resolver.from_address) if result.reason

    user = result.user
    unless user.preview_features_enabled?
      notify_preview_required(user)
      return reject!("preview_required", from: resolver.from_address, user:)
    end

    # Created with its original or not at all, so a retry of this email doesn't leave a
    # purchase behind that nothing will read.
    purchase = Purchase.transaction do
      Purchase.create!(
        family: user.family, user:, source: :email, status: :processing, inbound_email_message_id: mail.message_id
      ).tap do |created|
        created.original_email.attach(io: StringIO.new(inbound_email.source), filename: "order.eml", content_type: "message/rfc822")
      end
    end
    start_reading(purchase)
  end

  private
    # A purchase whose job can't be queued is failed rather than left processing, so the user
    # can read it again from its page.
    def start_reading(purchase)
      Purchase::EmailProcessJob.perform_later(purchase)
    rescue StandardError => e
      purchase.update!(status: :failed, error: "The email couldn't be queued for reading: #{e.message}")
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "error",
        message: "Couldn't queue a forwarded order email for reading: #{e.message}",
        source: self.class.name,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, inbound_email_id: inbound_email.id, error_class: e.class.name }
      )
    end

    def reject!(reason, from:, user: nil)
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "info",
        message: "Order email rejected: #{reason}",
        source: self.class.name,
        user:,
        metadata: { inbound_email_id: inbound_email.id, reason:, from:, subject: mail.subject }
      )
      bounced!
    end

    # At most one reminder a day, so a mail filter forwarding many orders doesn't flood the user.
    def notify_preview_required(user)
      today = Date.current.iso8601
      return if user.preferences["purchase_inbox_preview_notice_on"] == today

      user.update!(preferences: user.preferences.merge("purchase_inbox_preview_notice_on" => today))
      PurchaseMailer.with(user:).preview_required.deliver_later
    end
end
