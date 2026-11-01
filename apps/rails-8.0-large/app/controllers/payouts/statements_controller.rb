module Payouts
  class StatementsController < ApplicationController
    include CurrentTenant
    include Pundit::Authorization
    before_action :require_session

    def show
      @statement = Statement.joins(:payout_run).where(payouts_payout_runs: { organization_id: current_organization.id })
        .includes(:payee, :earnings, :transfer, :payout_run).find(params[:id])
      authorize @statement
      if params[:preview] == '1'
        @breakdown = Canopy::RoyaltyCalculator.new.breakdown(@statement.earnings)
      end
      respond_to do |format|
        format.html
        format.json { render json: StatementSerializer.new(@statement).as_json }
      end
    end

    private

    def pundit_user = current_author
  end
end
