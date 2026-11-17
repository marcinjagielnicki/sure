require "test_helper"

class PurchasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    sign_in @user
    @awaiting = purchases(:allegro_awaiting)
    @matched = purchases(:allegro_matched)
  end

  test "needs preview features" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get purchases_url

    assert_redirected_to root_path
  end

  test "lists the user's purchases" do
    get purchases_url

    assert_response :success
    assert_includes response.body, purchase_path(@awaiting)
    assert_includes response.body, purchase_path(@matched)
  end

  test "the list opens with this month's summary" do
    travel_to Date.new(2026, 11, 17) do
      @matched.update!(ordered_on: Date.new(2026, 11, 2), total: 42)
      @awaiting.update!(ordered_on: Date.new(2026, 10, 1))

      get purchases_url

      assert_select "[data-testid=purchases-summary]" do
        assert_select "*", text: /\$42\.00/
        assert_select "*", text: /Allegro/
      end
    end
  end

  test "groups purchases by month, newest first, with undated ones last" do
    @matched.update!(ordered_on: Date.new(2026, 11, 2))
    @awaiting.update!(ordered_on: Date.new(2026, 10, 5))
    Purchase.create!(family: @user.family, user: @user, source: :email, status: :failed)

    get purchases_url

    headers = css_select("[data-testid=purchase-month]").map { _1.text.squish }
    assert_equal 3, headers.size
    assert_match "November 2026", headers[0]
    assert_match "October 2026", headers[1]
    assert_match "No date", headers[2]
  end

  test "a row leads with what was bought and how many more items" do
    @matched.items.create!(name: "Milk", amount: 0, position: 1)

    get purchases_url

    assert_select "a[href='#{purchase_path(@matched)}']", text: /Coffee beans\s*\+1/
  end

  test "a shop with a known domain shows its Brandfetch logo" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    @awaiting.update!(merchant_domain: "allegro.pl")

    get purchases_url

    assert_select "a[href='#{purchase_path(@awaiting)}'] img[src^='https://cdn.brandfetch.io/allegro.pl/icon']"
  end

  test "without Brandfetch a shop gets its initial instead of a broken image" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @awaiting.update!(merchant_domain: "allegro.pl")

    get purchases_url

    assert_select "a[href='#{purchase_path(@awaiting)}'] img", count: 0
    assert_select "a[href='#{purchase_path(@awaiting)}']", text: /A/
  end

  test "the to-match tab lists only purchases waiting for a payment" do
    get purchases_url(tab: "to_match")

    assert_includes response.body, purchase_path(@awaiting)
    refute_includes response.body, purchase_path(@matched)
  end

  test "searches item names" do
    get purchases_url(q: "coffee")

    assert_includes response.body, purchase_path(@matched)
    refute_includes response.body, purchase_path(@awaiting)
  end

  test "shows a purchase with its items and transaction" do
    get purchase_url(@matched)

    assert_response :success
    assert_includes response.body, "Coffee beans"
    assert_includes response.body, "Starbucks"
  end

  test "another member's unlinked purchase is not found" do
    member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    sign_in member

    get purchase_url(@awaiting)

    assert_response :not_found
  end

  test "dismiss stops matching" do
    post dismiss_purchase_url(@awaiting)

    assert_redirected_to purchase_url(@awaiting)
    assert_equal "dismissed", @awaiting.reload.status
  end

  test "reprocess restarts a failed email purchase only" do
    @awaiting.update!(status: :failed)

    assert_enqueued_with(job: Purchase::EmailProcessJob) { post reprocess_purchase_url(@awaiting) }
    assert_equal "processing", @awaiting.reload.status

    assert_no_enqueued_jobs(only: Purchase::EmailProcessJob) { post reprocess_purchase_url(@matched) }
  end

  test "the original email downloads as an attachment, never inline" do
    @awaiting.original_email.attach(io: StringIO.new("From: a@b.c\r\n\r\n<script>x</script>"), filename: "order.eml", content_type: "message/rfc822")

    get original_email_purchase_url(@awaiting)

    assert_response :success
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert_equal "message/rfc822", response.media_type
  end

  test "a receipt purchase has no original email to download" do
    @matched.update!(source: :receipt)

    get original_email_purchase_url(@matched)

    assert_response :not_found
  end

  test "the AI output is shown escaped" do
    @matched.update!(ai_metadata: { "raw_output" => { "notes" => "<script>alert(1)</script>" } })

    get purchase_url(@matched)

    refute_includes response.body, "<script>alert(1)</script>"
    assert_includes response.body, "&lt;script&gt;"
  end

  test "only the purchase's owner can download the original email" do
    @matched.original_email.attach(io: StringIO.new("From: a@b.c\r\n\r\nhome address"), filename: "order.eml", content_type: "message/rfc822")
    member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    sign_in member

    get original_email_purchase_url(@matched)

    assert_response :not_found
  end

  test "filters by order date from the page" do
    get purchases_url(start_date: @awaiting.ordered_on.iso8601, end_date: @awaiting.ordered_on.iso8601)

    assert_includes response.body, purchase_path(@awaiting)
    refute_includes response.body, purchase_path(@matched)
    assert_select "input[type=date][name=start_date][value='#{@awaiting.ordered_on.iso8601}']"
    assert_select "input[type=date][name=end_date]"
  end

  test "the mismatch warning shows the numbers" do
    @matched.update!(review_reasons: [ { "reason" => "items_mismatch", "expected" => "62.63", "actual" => "80.0",
                                         "items" => "73.58", "shipping" => "0.0", "discount" => "10.95" } ])

    get purchase_url(@matched)

    assert_includes response.body, "$73.58"
    assert_includes response.body, "$10.95"
    assert_includes response.body, "$80.00"
  end
end
