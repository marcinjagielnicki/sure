namespace :purchases do
  desc "Create purchases for receipt scans processed before purchases existed"
  task backfill_receipts: :environment do
    created = skipped = 0

    ReceiptScan.where(status: %w[completed needs_review]).where.missing(:purchase).find_each do |scan|
      receipt = scan.linked_transaction&.extra&.dig("receipt")
      if receipt.blank?
        skipped += 1
        next
      end

      Purchase::FromReceiptScan.sync!(scan, extraction_hash: receipt, ai_metadata: { "backfilled" => true, "raw_output" => receipt })
      created += 1
    end

    puts "created=#{created} skipped=#{skipped}"
  end
end
