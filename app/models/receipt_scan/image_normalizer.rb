# Turns an uploaded receipt photo into an upright, metadata-free JPEG small enough to send to a
# vision model: phones store rotation in EXIF, iPhones shoot HEIC (which Claude doesn't accept),
# and EXIF carries the location the photo was taken. PDFs pass through untouched.
class ReceiptScan::ImageNormalizer
  UnsupportedFile = Class.new(StandardError)

  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
  MAX_DIMENSION = 2000
  JPEG_QUALITY = 85

  def self.call(io:, content_type:, filename:)
    new(io:, content_type:, filename:).call
  end

  def initialize(io:, content_type:, filename:)
    @io = io
    @content_type = content_type.to_s.downcase
    @filename = filename.to_s
  end

  def call
    if content_type == "application/pdf"
      return { io: StringIO.new(io.read.b), content_type: "application/pdf", filename: }
    end
    unless content_type.in?(IMAGE_CONTENT_TYPES)
      raise UnsupportedFile, "Unsupported receipt file type: #{content_type.presence || "unknown"}"
    end

    { io: StringIO.new(jpeg_bytes), content_type: "image/jpeg", filename: "#{File.basename(filename, ".*")}.jpg" }
  end

  private
    attr_reader :io, :content_type, :filename

    def jpeg_bytes
      Tempfile.create([ "receipt", File.extname(filename) ], binmode: true) do |source|
        IO.copy_stream(io, source)
        source.flush

        output = ImageProcessing::Vips
          .source(source.path)
          .autorot
          .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
          .convert("jpg")
          .saver(quality: JPEG_QUALITY, strip: true)
          .call
        begin
          File.binread(output.path)
        ensure
          output.close!
        end
      end
    end
end
