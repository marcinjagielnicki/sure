require "test_helper"

class Purchase::EmailTextTest < ActiveSupport::TestCase
  test "reads a forwarded HTML order as text with table rows on their own lines" do
    result = text_for("amazon_manual_forward.eml")

    assert_includes result.text, "Order Total: $249.99"
    assert_includes result.text, "HEPA filter for XR-200 vacuum | HomeParts LLC | 2 | $79.98"
    assert_includes result.text, "View or manage order"
    refute_includes result.text, "<td"
    refute_includes result.text, "alert(1)"
    refute_includes result.text, "color:red"
    refute_includes result.text, "https://www.amazon.com/your-orders"
    assert_not result.truncated
  end

  test "lifts the forwarded message's headers to the top" do
    text = text_for("amazon_manual_forward.eml").text

    assert_match(/\AOriginal-From: Amazon.com <auto-confirm@amazon.com>\n/, text)
    assert_includes text, "Original-Date: Thu, Nov 12, 2026 at 6:42 PM"
    assert_includes text, "Original-Subject: Your Amazon.com order #112-1234567-1234567"
    assert_includes text, "Received-Date: Sun, 22 Nov 2026 09:15:00 -0500"
  end

  test "an automatically forwarded order uses its own headers" do
    text = text_for("amazon_auto_forward.eml").text

    assert_includes text, "Original-From: \"Amazon.com\" <auto-confirm@amazon.com>"
    assert_includes text, "Original-Date: Thu, 12 Nov 2026 18:42:00 -0500"
    assert_includes text, "Order #112-1234567-1234567"
  end

  test "reads an order forwarded as an attachment" do
    text = text_for("forward_as_attachment.eml").text

    assert_includes text, "Order Total: $249.99"
    assert_includes text, "Original-From: \"Amazon.com\" <auto-confirm@amazon.com>"
  end

  test "decodes ISO-8859-2" do
    text = text_for("iso_8859_2.eml").text

    assert_includes text, "Ship to: Łódź, Żółta St. 5"
    assert_includes text, "Order Total: $12.50"
  end

  test "falls back to the plain text part" do
    assert_includes text_for("not_an_order.eml").text, "Your package has shipped"
  end

  test "recognizes a Polish forward marker" do
    mail = Mail.new(body: "---------- Wiadomość przekazana dalej ---------\nOd: Sklep <shop@example.com>\nData: 12.11.2026\nTemat: Zamówienie\n\nDo zapłaty: 10,00 zł")

    text = Purchase::EmailText.new(mail).call.text

    assert_match(/\AOriginal-From: Sklep <shop@example.com>\nOriginal-Date: 12.11.2026\nOriginal-Subject: Zamówienie/, text)
  end

  test "truncates long emails and says so" do
    mail = Mail.new(body: "x" * 50_000)

    result = Purchase::EmailText.new(mail).call

    assert_equal Purchase::EmailText::MAX_CHARS, result.text.length
    assert result.truncated
    assert_equal 50_000, result.input_chars
  end

  private
    def text_for(name)
      Purchase::EmailText.new(Mail.new(file_fixture("purchase_emails/#{name}").binread)).call
    end
end
