# frozen_string_literal: true

module Admin
  class UsersController < Admin::BaseController
    before_action :authenticate_user!
    before_action :set_user, only: [ :show, :edit, :update, :destroy ]

    # UsersController uses policy_scope for custom scoping (super admins see all users)
    # This verification ensures we don't accidentally remove the policy_scope call
    after_action :verify_policy_scoped, only: :index

    def index
      @page_title = "Users"
      authorize User  # Checks UserPolicy#index? - required by verify_authorized
      @users = policy_scope(User)  # Filters collection - required by verify_policy_scoped
      @q = @users.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @users = pagy(@q.result)

      # Load filter options
      @filter_super_admin = [ [ "Yes", true ], [ "No", false ] ]
      @filter_companies = Company.order(:name).pluck(:name, :id) if policy(User).see_company_column?
    end

    def show
      authorize @user
    end

    def new
      @user = User.new
      authorize @user
      # Pre-assign company for non-super admins
      @user.current_company = current_user.company
      load_company_fields
    end

    def create
      @user = User.new
      authorize @user

      # Non-super admins can only create users in their own company
      @user.company = current_user.company unless policy(User).manage_company?

      if save_user(user_params)
        redirect_to user_path(@user), notice: "User was successfully created."
      else
        load_company_fields
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @user
      load_company_fields
    end

    def update
      authorize @user

      update_params = user_params

      # Remove password fields if blank
      if update_params[:password].blank?
        update_params = update_params.except(:password, :password_confirmation)
      end

      if save_user(update_params)
        # Refresh the changed password salt without replacing an impersonating admin's identity.
        if update_params[:password].present? && !impersonating? && @user == true_current_user
          bypass_sign_in(@user)
        end
        redirect_to user_path(@user), notice: "User was successfully updated.", status: :see_other
      else
        load_company_fields
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @user
      @user.destroy
      redirect_to users_path, notice: "User was successfully deleted.", status: :see_other
    end

    private

    def set_user
      # Use policy scope to find user - handles super_admin bypass
      @user = policy_scope(User).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to users_path, alert: "User not found."
    end

    def set_page_title
      @page_title = "Users"
    end

    def save_user(attributes)
      if policy(User).manage_company?
        @company_access = ::Users::SaveWithCompanyAccess.new(@user, attributes, default_company: current_user.company)
        @company_access.call
      else
        @user.assign_attributes(attributes)
        @user.save
      end
    end

    def load_company_fields
      return unless policy(User).manage_company?
      @companies = Company.order(:name)
      @selected_company_ids = @company_access&.selected_company_ids || @user.company_ids
      @selected_company_ids = [ @user.current_company_id ].compact if @user.new_record? && !@company_access
      @selected_current_company_id = @company_access ? @company_access.current_company_id : @user.current_company_id
    end

    def user_params
      permitted = [ :email, :password, :password_confirmation, :time_zone ]
      permitted << :super_admin if policy(User).manage_super_admin_flag?
      if policy(User).manage_company?
        permitted << :current_company_id
        permitted << { company_ids: [] }
      end
      params.require(:user).permit(permitted)
    end
  end
end
