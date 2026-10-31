# Payout pages. Drawn from config/routes.rb.
namespace :payouts do
  resources :payees, only: %i[index show create]
  resources :payout_runs, only: %i[index show create] do
    member { post :finalize }
  end
  resources :statements, only: :show
end
