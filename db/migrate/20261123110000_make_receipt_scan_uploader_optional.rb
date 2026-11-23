# Installs that created receipt_scans before the uploader became optional have a NOT NULL
# user_id and a plain foreign key. Brings them in line with CreateReceiptScans; a no-op where
# the table was created with the current definition.
class MakeReceiptScanUploaderOptional < ActiveRecord::Migration[8.1]
  def up
    change_column_null :receipt_scans, :user_id, true
    remove_foreign_key :receipt_scans, :users if foreign_key_exists?(:receipt_scans, :users)
    add_foreign_key :receipt_scans, :users, on_delete: :nullify
  end

  def down
    remove_foreign_key :receipt_scans, :users if foreign_key_exists?(:receipt_scans, :users)
    add_foreign_key :receipt_scans, :users
  end
end
