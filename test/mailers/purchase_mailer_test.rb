require "test_helper"

class PurchaseMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @user = users(:family_admin)
    @purchase = purchases(:allegro_matched)
    @purchase.update!(merchant: "Amazon.com", order_number: "112-1234567-1234567", total: BigDecimal("10.00"), currency: "USD")
    default_url_options[:host] = "example.com"
  end

  test "processed lists the items and the linked transaction" do
    mail = PurchaseMailer.with(purchase: @purchase).processed

    assert_equal [ @user.email ], mail.to
    assert_equal I18n.t("purchase_mailer.processed.subject", merchant: "Amazon.com", total: "$10.00"), mail.subject
    body = mail.text_part.body.decoded
    assert_includes body, "Coffee beans"
    assert_includes body, "Food & Drink"
    assert_includes body, "Starbucks"
    assert_includes body, purchase_url(@purchase)
  end

  test "processed says it waits for the payment when nothing is linked" do
    purchase = purchases(:allegro_awaiting)

    body = PurchaseMailer.with(purchase:).processed.text_part.body.decoded

    assert_includes body, I18n.t("purchase_mailer.processed.waiting")
  end

  test "matched names the transaction" do
    body = PurchaseMailer.with(purchase: @purchase).matched.text_part.body.decoded

    assert_includes body, "Starbucks"
    assert_includes body, purchase_url(@purchase)
  end

  test "unmatched links to the purchases waiting for a match" do
    purchase = purchases(:allegro_awaiting)

    body = PurchaseMailer.with(purchase:).unmatched.text_part.body.decoded

    assert_includes body, purchases_url(tab: "to_match")
  end

  test "rejected gives the model's reason and the email subject" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :rejected, ai_metadata: { "raw_output" => { "not_order_reason" => "Shipping notification" }, "subject" => "Your package has shipped" })
    purchase.flag!(:not_an_order)

    body = PurchaseMailer.with(purchase:).rejected.text_part.body.decoded

    assert_includes body, "Shipping notification"
    assert_includes body, "Your package has shipped"
  end

  test "rejected as a duplicate links the existing purchase" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :rejected)
    purchase.flag!(:duplicate, purchase_id: @purchase.id)

    body = PurchaseMailer.with(purchase:).rejected.text_part.body.decoded

    assert_includes body, purchase_url(@purchase)
  end

  test "failed never shows the provider's error message" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :failed, error: "secret upstream detail")

    mail = PurchaseMailer.with(purchase:).failed

    refute_includes mail.text_part.body.decoded, "secret upstream detail"
    refute_includes mail.html_part.body.decoded, "secret upstream detail"
  end

  test "preview_required points at the preferences" do
    mail = PurchaseMailer.with(user: @user).preview_required

    assert_equal [ @user.email ], mail.to
    assert_includes mail.text_part.body.decoded, settings_preferences_url
  end

  test "uses the user's locale when set" do
    @user.update!(locale: "pl")

    expected = I18n.with_locale(:pl) do
      I18n.t("purchase_mailer.processed.subject", merchant: "Amazon.com", total: Money.new(BigDecimal("10"), "USD").format)
    end

    I18n.with_locale(:en) do
      assert_equal expected, PurchaseMailer.with(purchase: @purchase).processed.subject
    end
    assert_not_equal "$10.00", expected.split(", ").last
  end
end
