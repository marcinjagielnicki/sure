require "test_helper"

class PurchaseInbox::PollerTest < ActiveSupport::TestCase
  FetchData = Struct.new(:attr)

  # Stands in for Net::IMAP: holds messages by UID and records what the poller did to them.
  class FakeImap
    attr_reader :calls, :seen, :moved, :deleted, :created

    def initialize(messages:, capabilities: %w[IMAP4REV1 MOVE], authserv_header: nil)
      @messages = messages
      @capabilities = capabilities
      @calls = []
      @seen = []
      @moved = []
      @deleted = []
      @created = []
    end

    def login(user, password) = @calls << [ :login, user, password ]
    def select(folder) = @calls << [ :select, folder ]
    def uid_search(_keys) = @messages.keys
    def capability = @capabilities
    def logout = @calls << [ :logout ]
    def disconnect = @calls << [ :disconnect ]
    def expunge = @calls << [ :expunge ]
    def create(folder) = @created << folder

    def uid_fetch(uid, attrs)
      raw = @messages.fetch(uid)
      if attrs == [ "RFC822.SIZE" ]
        [ FetchData.new({ "RFC822.SIZE" => raw.bytesize }) ]
      else
        [ FetchData.new({ "BODY[]" => raw }) ]
      end
    end

    def uid_store(uid, _op, flags)
      @seen << uid if flags.include?(:Seen)
      @deleted << uid if flags.include?(:Deleted)
    end

    def uid_move(uid, folder) = @moved << [ uid, folder ]
    def uid_copy(uid, folder) = @moved << [ uid, folder ]
  end

  setup do
    @raw = file_fixture("purchase_emails/amazon_manual_forward.eml").read
    @config = PurchaseInbox::Config.new(
      enabled: true, host: "imap.example.com", port: 993, ssl: true, username: "orders@example.com",
      password: "secret", folder: "INBOX", processed_folder: "Sure/Processed", shop_domains: [ "amazon.com" ],
      authserv_id: "mx.google.com", require_sender_auth: true
    )
  end

  test "stores unseen messages as inbound emails, marks them seen and moves them" do
    imap = FakeImap.new(messages: { 7 => @raw })

    assert_difference -> { ActionMailbox::InboundEmail.count }, 1 do
      assert_equal 1, poll(imap)
    end

    assert_equal [ 7 ], imap.seen
    assert_equal [ [ 7, "Sure/Processed" ] ], imap.moved
    assert_equal [ "Sure/Processed" ], imap.created
    assert_includes imap.calls, [ :login, "orders@example.com", "secret" ]
    assert_includes imap.calls, [ :select, "INBOX" ]
    assert_includes imap.calls, [ :logout ]
  end

  test "copies, deletes and expunges when the server can't MOVE" do
    imap = FakeImap.new(messages: { 7 => @raw }, capabilities: %w[IMAP4REV1])

    poll(imap)

    assert_equal [ [ 7, "Sure/Processed" ] ], imap.moved
    assert_equal [ 7 ], imap.deleted
    assert_includes imap.calls, [ :expunge ]
  end

  test "skips and marks seen a message that's too large" do
    imap = FakeImap.new(messages: { 7 => "x" * (PurchaseInbox::Poller::MAX_BYTES + 1) })

    assert_no_difference -> { ActionMailbox::InboundEmail.count } do
      assert_equal 0, poll(imap)
    end
    assert_equal [ 7 ], imap.seen
  end

  test "a message already received is not stored twice" do
    poll(FakeImap.new(messages: { 7 => @raw }))

    assert_no_difference -> { ActionMailbox::InboundEmail.count } do
      poll(FakeImap.new(messages: { 8 => @raw }))
    end
  end

  test "takes at most fifty messages per run" do
    messages = (1..55).to_h { |uid| [ uid, @raw.sub(/Message-ID: <[^>]+>/, "Message-ID: <m#{uid}@fixture.example>") ] }
    imap = FakeImap.new(messages:)

    assert_equal 50, poll(imap)
  end

  test "test_connection reports the message count and the authentication hosts on the latest message" do
    imap = FakeImap.new(messages: { 7 => @raw })
    def imap.status(_folder, _attrs) = { "MESSAGES" => 3 }

    result = PurchaseInbox::Poller.test_connection(config: @config, imap_factory: ->(_c) { imap })

    assert result[:ok]
    assert_equal 3, result[:message_count]
    assert_equal [ "mx.google.com" ], result[:authserv_ids]
  end

  test "test_connection reports a login error without the password" do
    imap = FakeImap.new(messages: {})
    def imap.login(*) = raise(Net::IMAP::NoResponseError.new(Struct.new(:data).new(Struct.new(:text).new("Invalid credentials"))))

    result = PurchaseInbox::Poller.test_connection(config: @config, imap_factory: ->(_c) { imap })

    assert_not result[:ok]
    assert_match "Invalid credentials", result[:error]
    refute_includes result[:error], "secret"
  end

  private
    def poll(imap)
      PurchaseInbox::Poller.new(config: @config, imap_factory: ->(_c) { imap }).poll!
    end
end
