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

    purchase = Purchase.create!(
      family: user.family, user:, source: :email, status: :processing, inbound_email_message_id: mail.message_id
    )
    purchase.original_email.attach(io: StringIO.new(inbound_email.source), filename: "order.eml", content_type: "message/rfc822")
    Purchase::EmailProcessJob.perform_later(purchase)
  end

  private
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
