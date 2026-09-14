Rails.application.routes.draw do
  resource :demo_session, only: %i[show create update destroy]
  resources :articles, only: %i[index show new create edit update] do
    resources :comments, only: %i[index create]
    member do
      post :submit
      post :decide
      post :publish
      post :schedule
    end
  end
  get '/read/:slug', to: 'public_articles#show', as: :read_article
  namespace :billing do
    resources :invoices, only: %i[index show] do
      member { post :pay; post :refund }
    end
  end
  resources :collections, only: %i[index show create update]
  resources :subscribers, only: %i[index show create] do
    member { post :subscribe; post :cancel }
  end
  namespace :newsletter do
    resources :campaigns, only: %i[index show create] do
      member { post :send_campaign; post :drain; post :engage }
    end
  end
  namespace :support do
    resources :tickets, only: %i[index show create update]
  end
  post '/graphql', to: 'graphql#create'
  post '/run_due', to: 'dashboard#run_due', as: :run_due
  post '/webhooks/:id/retry', to: 'dashboard#retry_webhook', as: :retry_webhook
  root 'dashboard#index'
end
