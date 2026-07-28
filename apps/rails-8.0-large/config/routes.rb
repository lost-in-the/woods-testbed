Rails.application.routes.draw do
  resources :accounts, only: %i[index show]
  root "accounts#index"
end
