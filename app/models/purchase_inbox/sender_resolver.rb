# Decides whose an incoming email is, and whether it can be trusted. A manual forward comes from
# the user's own address (a `sender` route); an automatic forward keeps the shop's From and is
# sent to the mailbox's plus address (a `tag` route) from an allowed shop domain. When sender
# authentication is on, the mail server's Authentication-Results must show the From domain passed
# DMARC or aligned DKIM; only results written by the configured mail server are trusted, since
# anyone can add such a header further down.
class PurchaseInbox::SenderResolver
  Result = Data.define(:user, :route_kind, :reason)

  RECIPIENT_HEADERS = %w[Delivered-To X-Original-To To Cc].freeze

  def initialize(mail, config: PurchaseInbox.config)
    @mail = mail
    @config = config
  end

  def result
    route = tag_route || sender_route
    return failure("unknown_sender") unless route
    return failure("sender_not_authenticated") if config.require_sender_auth && !authenticated?

    Result.new(user: route.user, route_kind: route.kind, reason: nil)
  end

  def from_address
    @from_address ||= Array(mail.from).first.to_s.strip.downcase
  end

  private
    attr_reader :mail, :config

    def failure(reason)
      Result.new(user: nil, route_kind: nil, reason:)
    end

    def from_domain
      from_address.split("@", 2).last.to_s
    end

    def tag_route
      return unless shop_domain?(from_domain)

      tags = recipient_addresses.filter_map { |address| address[/\A[^@+]+\+([^@]+)@/, 1] }
      PurchaseInboxRoute.tag.includes(:user).find_by(value: tags) if tags.any?
    end

    def sender_route
      PurchaseInboxRoute.sender.includes(:user).find_by(value: from_address) if from_address.present?
    end

    def recipient_addresses
      RECIPIENT_HEADERS.flat_map do |name|
        Array(mail.header[name]).flat_map { |field| field.value.to_s.scan(/[^\s<>,;"]+@[^\s<>,;"]+/) }
      end.map(&:downcase).uniq
    end

    def shop_domain?(domain)
      domain.present? && config.shop_domains.any? { |shop| domain == shop || domain.end_with?(".#{shop}") }
    end

    def authenticated?
      results = trusted_results
      return false unless results

      methods = results.split(";").map(&:strip)
      methods.any? { |method| dmarc_pass?(method) || dkim_pass?(method) || method.match?(/\Aarc=pass\b/) }
    end

    # The topmost Authentication-Results written by the configured mail server.
    def trusted_results
      return if config.authserv_id.blank?

      Array(mail.header["Authentication-Results"]).map { _1.value.to_s }.find do |value|
        value.split(";").first.to_s.strip.split(/\s+/).first.to_s.downcase == config.authserv_id
      end
    end

    def dmarc_pass?(method)
      return false unless method.match?(/\Admarc=pass\b/)

      header_from = method[/header\.from=([^\s;]+)/, 1]
      header_from.nil? || aligned?(header_from)
    end

    def dkim_pass?(method)
      return false unless method.match?(/\Adkim=pass\b/)

      domain = method[/header\.d=([^\s;]+)/, 1] || method[/header\.i=[^@\s;]*@([^\s;]+)/, 1]
      domain.present? && aligned?(domain)
    end

    # The authenticated domain is the From domain or a parent of it.
    def aligned?(domain)
      domain = domain.downcase
      from_domain == domain || from_domain.end_with?(".#{domain}")
    end
end
