class ContributorMailer < ApplicationMailer
  def statement_ready(statement)
    @statement = statement
    @payee = statement.payee
    profile = @payee.profile
    recipient = @payee.payouts_agency_profile? ? profile.contact_email : profile.author.email
    mail(to: recipient, subject: "Your #{statement.payout_run.period_start.strftime('%B %Y')} statement is ready")
  end
end
