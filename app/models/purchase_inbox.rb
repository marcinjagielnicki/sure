# The order mailbox: one IMAP mailbox per instance that family members forward shop order emails
# to. Settings live in Setting (purchase_inbox_*), edited on the order mailbox settings page.
module PurchaseInbox
  Config = Data.define(
    :enabled, :host, :port, :ssl, :username, :password, :folder, :processed_folder,
    :shop_domains, :authserv_id, :require_sender_auth
  )

  module_function

  def config
    Config.new(
      enabled: Setting.purchase_inbox_enabled,
      host: Setting.purchase_inbox_host,
      port: Setting.purchase_inbox_port,
      ssl: Setting.purchase_inbox_ssl,
      username: Setting.purchase_inbox_username,
      password: Setting.purchase_inbox_password,
      folder: Setting.purchase_inbox_folder.presence || "INBOX",
      processed_folder: Setting.purchase_inbox_processed_folder.presence,
      shop_domains: Array(Setting.purchase_inbox_shop_domains).map { _1.to_s.strip.downcase }.compact_blank,
      authserv_id: Setting.purchase_inbox_authserv_id.to_s.strip.downcase.presence,
      require_sender_auth: Setting.purchase_inbox_require_sender_auth
    )
  end

  # Enough settings to log in, and a trusted authentication host when senders must be verified.
  def configured?(config = self.config)
    config.enabled && config.host.present? && config.username.present? && config.password.present? &&
      (!config.require_sender_auth || config.authserv_id.present?)
  end

  def record_poll!(error: nil)
    Setting.purchase_inbox_last_polled_at = Time.current
    Setting.purchase_inbox_last_error = error
  end
end
