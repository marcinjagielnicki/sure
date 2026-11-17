module PurchasesHelper
  # One review note on a purchase, with the numbers when a total didn't add up.
  def purchase_review_reason(purchase, reason)
    key = reason["reason"].to_s
    if key == "items_mismatch" && reason["items"]
      currency = purchase.currency.presence || Current.family.currency
      money = ->(value) { format_money(Money.new(BigDecimal(value.to_s), currency)) }
      t("purchases.review_reasons.items_mismatch_detail",
        items: money.(reason["items"]), shipping: money.(reason["shipping"]), discount: money.(reason["discount"]),
        expected: money.(reason["expected"]), actual: money.(reason["actual"]))
    else
      t("purchases.review_reasons.#{key}", default: key.humanize)
    end
  end

  # The shop's logo: Brandfetch by the shop's domain, else the linked transaction's merchant logo.
  def purchase_logo_url(purchase)
    Setting.brand_fetch_icon_url(purchase.merchant_domain) ||
      purchase.linked_transaction&.merchant&.logo_url.presence&.then { Setting.transform_brand_fetch_url(_1) }
  end
end
