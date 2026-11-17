require "test_helper"

class Purchase::LinkerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @food = categories(:food_and_drink)
    @household = @family.categories.create!(name: "Household", color: "#000000")
    @shopping = @family.categories.create!(name: "Shopping", color: "#000000")
    @purchase = purchases(:allegro_awaiting)
    @purchase.update!(total: BigDecimal("100.00"), currency: "USD", ordered_on: Date.current - 2.days)
    @purchase.items.create!(name: "Coffee", amount: 60, category: @food, position: 0)
    @purchase.items.create!(name: "Soap", amount: 40, category: @household, position: 1)
    @entry = create_transaction(account: accounts(:depository), amount: 100, date: Date.current - 1.day, name: "Allegro")
  end

  test "links the transaction and records the purchase on it" do
    @purchase.link!(@entry)

    @purchase.reload
    assert_equal "matched", @purchase.status
    assert_equal @entry.entryable, @purchase.linked_transaction
    assert_not_nil @purchase.matched_at
    assert_equal({ "purchase_id" => @purchase.id, "merchant" => "Allegro", "order_number" => "A-1001" }, @entry.reload.entryable.extra["purchase"])
  end

  test "several category groups split the transaction" do
    @purchase.link!(@entry)

    children = @entry.reload.child_entries.order(:amount)
    assert_equal [ BigDecimal("40"), BigDecimal("60") ], children.map(&:amount)
    assert_equal [ @household, @food ], children.map { _1.entryable.category }
  end

  test "one category group sets and locks the category, overriding a rule's category" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @entry.entryable.enrich_attribute(:category_id, @shopping.id, source: "rule")

    @purchase.link!(@entry)

    transaction = @entry.reload.entryable
    assert_equal @food, transaction.category
    assert transaction.locked?(:category_id)
    assert_not @entry.split_parent?
  end

  test "a category the user set is left alone" do
    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)

    @purchase.link!(@entry)

    assert_equal @shopping, @entry.reload.entryable.category
    assert_not @entry.split_parent?
    assert_equal "matched", @purchase.reload.status
  end

  test "an already split transaction is linked without changes" do
    @entry.split!([ { name: "A", amount: 50, category_id: nil }, { name: "B", amount: 50, category_id: nil } ])

    @purchase.link!(@entry)

    assert_equal [ BigDecimal("50"), BigDecimal("50") ], @entry.reload.child_entries.map(&:amount)
    assert_equal "matched", @purchase.reload.status
  end

  test "a manual link to a different amount links without categorizing and flags it" do
    other = create_transaction(account: accounts(:depository), amount: 120, date: Date.current, name: "Allegro")

    @purchase.link!(other, manual: true)

    assert_equal "matched", @purchase.reload.status
    assert_not other.reload.split_parent?
    assert_equal [ { "reason" => "amount_differs", "entry_id" => other.id } ], @purchase.review_reasons
  end

  test "linking an entry on an account the user cannot change raises" do
    @purchase.update!(user: users(:family_member))
    read_only = create_transaction(account: accounts(:credit_card), amount: 100, date: Date.current)

    assert_raises(Purchase::LinkError) { @purchase.link!(read_only, manual: true) }
    assert_nil @purchase.reload.transaction_id
  end

  test "linking an entry another purchase already has raises" do
    purchases(:allegro_matched).update!(linked_transaction: @entry.entryable)

    assert_raises(Purchase::LinkError) { @purchase.link!(@entry, manual: true) }
  end

  test "unlink reopens the purchase and remembers the entry" do
    @purchase.link!(@entry)

    @purchase.unlink!

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_nil @purchase.transaction_id
    assert_equal [ @entry.id ], @purchase.rejected_entry_ids
    assert_nil @entry.reload.entryable.extra["purchase"]
  end

  test "dismiss stops matching" do
    @purchase.dismiss!

    assert_equal "dismissed", @purchase.reload.status
  end

  test "apply_match! records candidates when ambiguous and keeps an unmatched purchase unmatched" do
    second = create_transaction(account: accounts(:depository), amount: 100, date: Date.current, name: "Allegro")

    assert_equal :ambiguous, @purchase.apply_match!
    assert_equal "needs_matching", @purchase.reload.status
    assert_equal [ @entry.id, second.id ].sort, @purchase.match_candidate_entry_ids.sort

    @entry.destroy!
    second.destroy!
    @purchase.update!(status: :unmatched)
    assert_equal :none, @purchase.apply_match!
    assert_equal "unmatched", @purchase.reload.status
  end

  test "apply_match! moves a skipped purchase to unmatched" do
    @purchase.update!(payment_method: :installments)

    assert_equal :skipped, @purchase.apply_match!
    assert_equal "unmatched", @purchase.reload.status
  end
end
