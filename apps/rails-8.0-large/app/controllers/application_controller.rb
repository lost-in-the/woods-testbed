class ApplicationController < ActionController::Base
  allow_browser versions: :modern if respond_to?(:allow_browser)
end
