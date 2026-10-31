module Payouts
  class PayoutRunsController < ApplicationController
    include CurrentTenant
    before_action :require_session
    before_action :require_editor

    def index
      @runs = scope.order(period_start: :desc).limit(25).offset(page_offset)
    end

    def show
      @run = scope.find(params[:id])
      @statements = @run.statements.includes(:payee).order(:id)
    end

    def create
      run = StartPayoutRun.new(author: current_author).call(organization: current_organization, period_start: Date.parse(params.require(:period_start)))
      redirect_to payouts_payout_run_path(run)
    end

    def finalize
      run = FinalizePayoutRun.new(author: current_author).call(scope.find(params[:id]))
      redirect_to payouts_payout_run_path(run)
    end

    private

    def scope = current_organization.payout_runs
  end
end
