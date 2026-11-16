class ReceiptScansController < ApplicationController
  include AiFeatureGuard

  before_action :require_preview_features!
  requires_ai :extract_receipt
  before_action :set_accounts

  def new
  end

  def create
    account = @accounts.find { |candidate| candidate.id == receipt_scan_params[:account_id] }
    return render_new_with_error(t(".account_required")) unless account

    ReceiptScan.create_from_upload!(
      family: Current.family,
      user: Current.user,
      account: account,
      uploads: Array(receipt_scan_params[:files]).compact_blank
    )

    redirect_to transactions_path, notice: t(".success")
  rescue ReceiptScan::InvalidUpload => e
    render_new_with_error(e.message)
  end

  private
    def set_accounts
      @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.to_a
    end

    def receipt_scan_params
      params.fetch(:receipt_scan, {}).permit(:account_id, files: [])
    end

    def render_new_with_error(message)
      @error = message
      render :new, status: :unprocessable_entity
    end
end
