require "test_helper"

RakeTaskTestHelper.load_task("purchases:backfill_receipts", "purchases")

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
end
