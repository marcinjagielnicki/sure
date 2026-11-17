# Turns a forwarded order email into plain text for the extraction model: the order's own HTML
# (or plain text) as readable lines, with the original sender, date and subject on top so the
# model reads the order date rather than the date it was forwarded.
class Purchase::EmailText
  MAX_CHARS = 40_000

  Result = Data.define(:text, :truncated, :input_chars)

  FORWARD_MARKERS = [
    /-{3,}\s*Forwarded message\s*-{3,}/i,
    /-{3,}\s*Wiadomość przekazana dalej\s*-{3,}/i,
    /-{3,}\s*Original Message\s*-{3,}/i,
    /Begin forwarded message:/i
  ].freeze
  FORWARDED_HEADERS = {
    "Original-From" => /^\s*(?:From|Od):\s*(.+)$/i,
    "Original-Date" => /^\s*(?:Date|Data|Sent|Wysłano):\s*(.+)$/i,
    "Original-Subject" => /^\s*(?:Subject|Temat):\s*(.+)$/i
  }.freeze
  BLOCK_ELEMENTS = %w[p div br li tr h1 h2 h3 h4 h5 h6 table section article header footer].freeze

  def initialize(mail)
    @mail = mail
  end

  def call
    message = innermost_message
    body = readable_body(message)
    headers = (inline_forward_headers(body) if message.equal?(mail)).presence || own_headers(message)
    text = [ header_block(headers), body ].reject(&:blank?).join("\n\n")

    Result.new(text: text.first(MAX_CHARS), truncated: text.length > MAX_CHARS, input_chars: text.length)
  end

  private
    attr_reader :mail

    # An order forwarded as an attachment sits in a message/rfc822 part.
    def innermost_message
      message = mail
      while (part = message.all_parts.find { |candidate| candidate.mime_type == "message/rfc822" })
        message = Mail.new(part.body.decoded)
      end
      message
    end

    def readable_body(message)
      html = message.html_part || (message.mime_type == "text/html" ? message : nil)
      return html_to_text(decode(html)) if html

      plain = message.text_part || (message.multipart? ? nil : message)
      plain ? squeeze(decode(plain)) : ""
    end

    def decode(part)
      text = part.decoded.to_s
      text = text.dup.force_encoding(part.charset) if part.charset.present? && text.encoding == Encoding::BINARY
      text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    rescue ArgumentError, Encoding::ConverterNotFoundError
      part.body.decoded.to_s.dup.force_encoding("UTF-8").scrub("?")
    end

    def html_to_text(html)
      document = Nokogiri::HTML(html)
      document.css("script, style, head, img, noscript").remove
      document.css("td, th").each { |cell| cell.add_next_sibling(Nokogiri::XML::Text.new(" | ", document)) }
      document.css(BLOCK_ELEMENTS.join(", ")).each { |node| node.add_next_sibling(Nokogiri::XML::Text.new("\n", document)) }
      squeeze(document.text.gsub(/ \| \n/, "\n"))
    end

    def squeeze(text)
      text.gsub("\r", "").gsub(/[ \t ]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def own_headers(message)
      {
        "Original-From" => message[:from]&.decoded,
        "Original-Date" => message[:date]&.decoded,
        "Original-Subject" => message.subject
      }
    end

    # The header lines right after a "Forwarded message" marker in an inline forward.
    def inline_forward_headers(body)
      marker = FORWARD_MARKERS.lazy.filter_map { |pattern| body.match(pattern) }.first
      return {} unless marker

      block = body[marker.end(0)..].lines.first(8).join
      FORWARDED_HEADERS.transform_values { |pattern| block[pattern, 1]&.strip }.compact_blank
    end

    def header_block(headers)
      lines = headers.compact_blank.map { |name, value| "#{name}: #{value}" }
      lines << "Received-Date: #{mail[:date]&.decoded}" if mail[:date]
      lines.join("\n")
    end
end
