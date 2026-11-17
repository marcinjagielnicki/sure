require "test_helper"

class Purchase::EmailTextTest < ActiveSupport::TestCase
  test "reads a forwarded HTML order as text with table rows on their own lines" do
    result = text_for("allegro_manual_forward.eml")

    assert_includes result.text, "Do zapłaty: 249,99 zł"
    assert_match(/Filtr HEPA do odkurzacza XR-200 \| sklep_agd \| 2 \| 79,98 zł/, result.text)
    assert_includes result.text, "Szczegóły zamówienia"
    refute_includes result.text, "<td"
    refute_includes result.text, "alert(1)"
    refute_includes result.text, "color:red"
    refute_includes result.text, "https://allegro.pl/moje-allegro"
    assert_not result.truncated
  end

  test "lifts the forwarded message's headers to the top" do
    text = text_for("allegro_manual_forward.eml").text

    assert_match(/\AOriginal-From: Allegro <powiadomienia@allegro.pl>\n/, text)
    assert_includes text, "Original-Date: śr., 12 lis 2026 o 18:42"
    assert_includes text, "Original-Subject: Dziękujemy za zakup"
    assert_includes text, "Received-Date: "
  end

  test "an automatically forwarded order uses its own headers" do
    text = text_for("allegro_auto_forward.eml").text

    assert_includes text, "Original-From: Allegro <powiadomienia@allegro.pl>"
    assert_includes text, "Original-Date: Thu, 12 Nov 2026 18:42:00 +0100"
    assert_includes text, "Numer zamówienia: a1b2c3d4"
  end

  test "reads an order forwarded as an attachment" do
    text = text_for("forward_as_attachment.eml").text

    assert_includes text, "Numer zamówienia: a1b2c3d4"
    assert_includes text, "Original-From: Allegro <powiadomienia@allegro.pl>"
  end

  test "decodes ISO-8859-2" do
    text = text_for("iso_8859_2.eml").text

    assert_includes text, "Sklep w Łódź, ulica Żółta 5"
    assert_includes text, "Do zapłaty: 12,50 zł"
  end

  test "falls back to the plain text part" do
    assert_includes text_for("not_an_order.eml").text, "Twoja paczka jest w drodze"
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
