Rails.application.routes.draw do
  # Woods Map explorer over the published index (woods-testbed#38). Gated by
  # WOODS_MAP_TOKEN from the compose environment; loopback needs no token.
  mount WoodsMap::Engine => "/woods"

  root   "static_pages#home"
  get    "/help",   to: "static_pages#help"
  get    "/about",  to: "static_pages#about"
  get    "/contact",to: "static_pages#contact"
  get    "/signup", to: "users#new"
  get    "/login",  to: "sessions#new"
  post   "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy"
  resources :users do
    member do
      get :following
      get :followers
    end
  end
  resources :account_activations, only: [:edit]
  resources :password_resets,     only: [:new, :create, :edit, :update]
  resources :microposts,          only: [:create, :destroy]
  resources :relationships,       only: [:create, :destroy]
  get '/microposts', to: 'static_pages#home'
end
