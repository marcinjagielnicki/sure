require "test_helper"

class Purchase::ValidatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a consistent order has no problems" do
    assert_empty problems
  end

  test "items plus shipping minus discounts must equal the total" do
    assert_equal [ "items_mismatch" ], reasons(total: BigDecimal("240.00"))
    assert_empty reasons(total: BigDecimal("239.99"), discount_total: BigDecimal("10.00"))
  end

  test "the mismatch check allows one cent of rounding" do
    assert_empty reasons(total: BigDecimal("250.00"))
  end

  test "no items means nothing to compare" do
    assert_empty reasons(items: [])
  end

  test "missing and non-positive totals" do
    assert_includes reasons(total: nil), "missing_total"
    assert_includes reasons(total: BigDecimal("0"), items: []), "non_positive_total"
  end

  test "missing, future and too old dates" do
    assert_includes reasons(order_date: nil), "missing_date"
    assert_includes reasons(order_date: Date.current + 1.day), "future_date"
    assert_includes reasons(order_date: Date.current - 1.year - 1.day), "too_old"
  end

  test "unknown currency" do
    assert_includes reasons(currency: "XYZ"), "unknown_currency"
    assert_includes reasons(currency: nil), "unknown_currency"
  end

  test "item categories that are not the family's" do
    items = [ { "name" => "A", "amount" => "249.99", "category_name" => "Not A Category" } ]

    found = problems(items:, shipping_cost: nil).find { _1["reason"] == "unknown_categories" }

    assert_equal [ "Not A Category" ], found["names"]
  end

  private
    def problems(**overrides)
      Purchase::Validator.new(build_purchase_extraction(**overrides), family: @family).problems
    end

    def reasons(**overrides)
      problems(**overrides).map { _1["reason"] }
    end
end
