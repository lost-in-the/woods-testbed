Rails.application.routes.draw do
  resources :articles, only: %i[index show] do
    resources :comments, only: %i[index create]
  end

  namespace :billing do
    resources :invoices, only: %i[index show]
  end

  root "articles#index"
end
