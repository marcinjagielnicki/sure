require "test_helper"

RakeTaskTestHelper.load_task("purchases:backfill_receipts", "purchases")
RakeTaskTestHelper.load_task("purchases:revalidate", "purchases")

class PurchasesRakeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    RakeTaskTestHelper.prepare("purchases:backfill_receipts")
    @scan = receipt_scans(:processing)
    entry = create_transaction(account: @scan.account, amount: 50, date: Date.current - 1.day, name: "Corner Grocer")
    entry.entryable.update!(extra: { "receipt" => build_receipt_extraction.to_h.as_json.merge("status" => "completed") })
    @scan.update!(linked_transaction: entry.entryable, status: :completed)

    @orphan = ReceiptScan.create!(family: @scan.family, user: @scan.user, account: @scan.account, status: :needs_review)
  end

  test "creates purchases for finished scans from their transaction's receipt data" do
    out, = capture_io { Rake::Task["purchases:backfill_receipts"].invoke }

    assert_match "created=1 skipped=1", out
    purchase = @scan.reload.purchase
    assert_equal "Corner Grocer", purchase.merchant
    assert purchase.ai_metadata["backfilled"]
    assert_nil @orphan.reload.purchase
  end

  test "running twice creates nothing new" do
    capture_io { Rake::Task["purchases:backfill_receipts"].invoke }
    RakeTaskTestHelper.prepare("purchases:backfill_receipts")

    out, = capture_io { Rake::Task["purchases:backfill_receipts"].invoke }

    assert_match "created=0 skipped=1", out
  end

  test "revalidate clears an items mismatch the current rules accept, without calling the AI" do
    purchase = purchases(:allegro_matched)
    raw = build_purchase_extraction(
      total: BigDecimal("73.58"), shipping_cost: BigDecimal("0"), discount_total: BigDecimal("10.95"),
      items: [ { "name" => "Filter", "amount" => "43.68" }, { "name" => "Bags", "amount" => "29.90" } ]
    ).to_h.as_json
    purchase.update!(ai_metadata: { "raw_output" => raw, "validation" => [ { "reason" => "items_mismatch" } ] },
                     review_reasons: [ { "reason" => "items_mismatch", "expected" => "62.63", "actual" => "73.58" } ])
    still_wrong = purchases(:allegro_awaiting)
    still_wrong.update!(ai_metadata: { "raw_output" => raw.merge("total" => "99.00") },
                        review_reasons: [ { "reason" => "items_mismatch" } ])
    RakeTaskTestHelper.prepare("purchases:revalidate")
    Provider::Registry.expects(:preferred_llm_provider).never

    out, = capture_io { Rake::Task["purchases:revalidate"].invoke }

    assert_match "cleared=1", out
    assert_empty purchase.reload.review_reasons
    assert_empty purchase.ai_metadata["validation"]
    assert_equal [ "items_mismatch" ], still_wrong.reload.review_reasons.map { _1["reason"] }
  end
end
