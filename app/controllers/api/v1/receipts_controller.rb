# frozen_string_literal: true

class Api::V1::ReceiptsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create ]

  def create
    account = target_account
    return if performed?

    @scan = ReceiptScan.create_from_upload!(
      family: family,
      user: current_resource_owner,
      account: account,
      uploads: Array(params[:files])
    )

    render :show, status: :accepted
  rescue ReceiptScan::InvalidUpload => e
    render_validation_error(e.message)
  end

  def show
    @scan = family.receipt_scans
      .where(account_id: current_resource_owner.accessible_accounts.select(:id))
      .find_by(id: params[:id]) if valid_uuid?(params[:id])

    return render_json({ error: "not_found", message: "Receipt not found" }, status: :not_found) unless @scan

    render :show
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def family
      current_resource_owner.family
    end

    def target_account
      account_id = params[:account_id].presence
      account = family.accounts.writable_by(current_resource_owner).find_by(id: account_id) if valid_uuid?(account_id)
      return account if account

      render_json({ error: "not_found", message: "No account you can write to matched account_id." }, status: :not_found)
      nil
    end
end
