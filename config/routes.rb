Rails.application.routes.draw do
  # Devise routes - OAuth callbacks added when engine configures auth_providers
  # Check both config and that User actually has :omniauthable (added by engine's to_prepare)
  devise_controllers = { sessions: "users/sessions" }
  if Scanner.configuration.auth_providers.any? && User.devise_modules.include?(:omniauthable)
    devise_controllers[:omniauth_callbacks] = "users/omniauth_callbacks"
  end

  devise_for :users,
    controllers: devise_controllers,
    path: "",
    path_names: { sign_in: "login", sign_out: "logout" }

  # ============================================================================
  # === ADMIN RESOURCES (mounted at root /) ===
  # ============================================================================
  # Using scope module: 'admin' to use Admin:: controllers without /admin prefix

  scope module: "admin" do
    # === ROOT ROUTE ===
    root "dashboard#index"

    # === Settings & Configuration ===
    resources :metadata
    get "release_notes", to: "release_notes#show", as: :release_notes
    get "glossary", to: "glossary#show", as: :glossary
    resources :environment_variables do
      collection do
        post :batch
        post :batch_destroy
      end
    end
    resources :users
    resources :companies
    resource :impersonation, only: [ :create, :destroy ], controller: "impersonations"
    resource :settings, only: [ :show, :update ]
    resources :output_servers, path: "integrations" do
      member do
        post :test
      end
    end

    # === Core Resources ===
    resources :probes, only: [ :index, :show ]

    resources :reports, only: [ :index, :show, :destroy ] do
      member do
        post :stop
        get :asr_history
        get :top_probes
        get :probes_tab
        get :probe_attempts
        get :attempt_content
        post :refresh_debug_lease
      end
      collection do
        post :batch
        post :batch_stop
        post :batch_destroy
      end
    end

    resources :targets do
      resources :environment_variables, only: [ :index, :new, :create ]
      member do
        post :validate
        patch :restore
      end
      collection do
        post :batch
        post :batch_validate
        post :batch_destroy
        post :auto_detect_selectors
      end
    end

    resources :scans do
      member do
        post :rerun
        get :stats
      end
      collection do
        post :batch
        post :batch_rerun
        post :batch_destroy
      end
    end
  end

  # ============================================================================
  # === API & System Routes ===
  # ============================================================================

  # Company switcher for multi-company users
  patch "switch_company/:id", to: "switch_company#update", as: :switch_company

  # SolidQueue dashboard (super admins only, auth enforced in MissionControlController)
  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post "mock_llm/chat", to: "mock_llm#chat"
      get "mock_llm/status", to: "mock_llm#status"
    end
  end

  resources :report_details, only: [ :show ] do
    member do
      get :pdf
      post :pdf_retry
      post :refresh_debug_lease
    end
  end

  resource :dashboard_stats, only: [] do
    get :total_scans_data
    get :probes_data
    get :last_five_scans_data
    get :targets_timeline_data
    get :reports_timeline_data
    get :probes_passed_failed_timeline_data
    get :probe_results_timeline_data
    get :probe_success_rate_data
    get :detector_activity_data
    get :attack_fails_by_target_data
    get :avg_asr_score
    get :avg_scan_time_data
    get :vulnerable_targets_over_time
    get :taxonomy_distribution_data
    get :probe_disclosure_stats
    get :scan_and_target_counts_over_time
  end
end
