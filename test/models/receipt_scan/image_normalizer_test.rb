require "test_helper"

class ReceiptScan::ImageNormalizerTest < ActiveSupport::TestCase
  test "normalizes rotated jpeg" do
    result = normalize("rotated.jpg", "image/jpeg")

    assert_upright_stripped_jpeg(result)
    assert_equal "rotated.jpg", result[:filename]
  end

  test "normalizes rotated heic" do
    skip "libvips without heif" unless Vips.get_suffixes.include?(".heic")

    result = normalize("rotated.heic", "image/heic")

    assert_upright_stripped_jpeg(result)
    assert_equal "rotated.jpg", result[:filename]
  end

  test "passes pdf through" do
    original = file_fixture("receipts/receipt.pdf").binread

    result = normalize("receipt.pdf", "application/pdf")

    assert_equal "application/pdf", result[:content_type]
    assert_equal original, result[:io].read.b
  end

  test "rejects text file" do
    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
      ReceiptScan::ImageNormalizer.call(io: StringIO.new("hello"), content_type: "text/plain", filename: "a.txt")
    end
  end

  private
    def normalize(name, content_type)
      File.open(file_fixture("receipts/#{name}"), "rb") do |io|
        ReceiptScan::ImageNormalizer.call(io:, content_type:, filename: name)
      end
    end

    def assert_upright_stripped_jpeg(result)
      assert_equal "image/jpeg", result[:content_type]
      image = Vips::Image.new_from_buffer(result[:io].read, "")
      assert_operator image.height, :>, image.width
      assert_equal 2000, [ image.width, image.height ].max
      assert_empty image.get_fields.grep(/exif|GPS/)
    end
end
