require "test_helper"

class ReceiptScanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "account must belong to the family" do
    scan = ReceiptScan.new(family: families(:empty), user: @user, account: @account)

    assert_not scan.valid?
    assert scan.errors.of_kind?(:account, :invalid)
  end

  test "starts processing" do
    scan = ReceiptScan.create!(family: @family, user: @user, account: @account)

    assert scan.processing?
    assert_equal [], scan.review_reasons
  end

  test "flag! records the reason and marks the scan for review" do
    scan = receipt_scans(:processing)

    scan.flag!(:total_mismatch, expected: "10.00")

    assert scan.reload.needs_review?
    assert_equal [ { "reason" => "total_mismatch", "expected" => "10.00" } ], scan.review_reasons
  end

  test "from_receipt? reads the transaction's extra" do
    transaction = transactions(:one)
    assert_not transaction.from_receipt?

    transaction.update!(extra: { "receipt" => { "status" => "processing" } })

    assert transaction.from_receipt?
  end
end
