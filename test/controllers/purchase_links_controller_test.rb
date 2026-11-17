require "test_helper"

class PurchaseLinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    sign_in @user
    @purchase = purchases(:allegro_awaiting)
    @entry = create_transaction(account: accounts(:depository), amount: BigDecimal("249.99"), date: @purchase.ordered_on, name: "AMAZON MKTP")
  end

  test "the dialog offers candidates first and searches transactions" do
    create_transaction(account: accounts(:depository), amount: 5, date: Date.current, name: "Corner shop")

    get new_purchase_link_url(@purchase)
    assert_response :success
    assert_includes response.body, "AMAZON MKTP"

    get new_purchase_link_url(@purchase, q: "corner")
    assert_includes response.body, "Corner shop"
  end

  test "links the chosen transaction" do
    post purchase_link_url(@purchase), params: { entry_id: @entry.id }

    assert_redirected_to purchase_url(@purchase)
    assert_equal @entry.entryable, @purchase.reload.linked_transaction
  end

  test "an entry on another family's account is not found" do
    other = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: other, amount: 1, date: Date.current)

    post purchase_link_url(@purchase), params: { entry_id: foreign.id }

    assert_response :not_found
    assert_nil @purchase.reload.transaction_id
  end

  test "an entry on a read-only shared account can't be linked" do
    member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    purchase = Purchase.create!(family: member.family, user: member, source: :email, status: :awaiting_payment, total: 1, currency: "USD")
    read_only = create_transaction(account: accounts(:credit_card), amount: 1, date: Date.current)
    sign_in member

    post purchase_link_url(purchase), params: { entry_id: read_only.id }

    assert_response :not_found
    assert_nil purchase.reload.transaction_id
  end

  test "unlinks the transaction" do
    @purchase.link!(@entry)

    delete purchase_link_url(@purchase)

    assert_redirected_to purchase_url(@purchase)
    assert_nil @purchase.reload.transaction_id
  end
end
