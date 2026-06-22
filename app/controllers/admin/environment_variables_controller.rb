# frozen_string_literal: true

module Admin
  class EnvironmentVariablesController < Admin::BaseController
    before_action :set_environment_variable, only: [ :show, :edit, :update, :destroy ]
    before_action :set_target, only: [ :index, :new, :create ]

    def index
      authorize EnvironmentVariable
      @page_title = "Environment Variables"

      base_scope = if @target
        @target.environment_variables
      else
        EnvironmentVariable.includes(:target)
      end

      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @environment_variables = pagy(@q.result)

      # Load filter options
      @filter_targets = Target.order(:name).pluck(:name, :id)
    end

    def show
      authorize @environment_variable
    end

    def new
      @environment_variable = EnvironmentVariable.new
      @environment_variable.target = @target if @target
      authorize @environment_variable
    end

    def create
      @environment_variable = EnvironmentVariable.new(environment_variable_params)
      authorize @environment_variable
      if @environment_variable.save
        redirect_to environment_variable_path(@environment_variable),
                    notice: "Environment variable was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @environment_variable
    end

    def update
      authorize @environment_variable
      if @environment_variable.update(environment_variable_params)
        redirect_to environment_variable_path(@environment_variable),
                    notice: "Environment variable was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @environment_variable
      @environment_variable.destroy
      redirect_to environment_variables_path,
                  notice: "Environment variable was successfully deleted.",
                  status: :see_other
    end

    # Unified batch action dispatcher (for shared table component)
    def batch
      authorize EnvironmentVariable, :index?
      case params[:batch_action]
      when "destroy"
        batch_destroy
      else
        redirect_to environment_variables_path, alert: "Unknown batch action"
      end
    end

    # Batch action: destroy multiple environment variables.
    # SECURITY: authorize explicitly (the standalone POST route can reach this without
    # going through #batch's dispatcher guard) and scope to the current tenant explicitly
    # — acts_as_tenant returns ALL rows when the tenant is nil, so an unscoped
    # `where(id:)` could delete other tenants' encrypted secrets.
    def batch_destroy
      authorize EnvironmentVariable, :batch_destroy?
      tenant = ActsAsTenant.current_tenant
      ids = params[:ids] || []
      scope = tenant ? EnvironmentVariable.where(company_id: tenant.id, id: ids) : EnvironmentVariable.none
      count = scope.destroy_all.count
      redirect_to environment_variables_path,
                  notice: "#{count} environment variable(s) were successfully deleted.",
                  status: :see_other
    end

    private

    def set_environment_variable
      @environment_variable = EnvironmentVariable.find(params[:id])
    end

    def set_target
      @target = Target.find(params[:target_id]) if params[:target_id]
    end

    def environment_variable_params
      params.require(:environment_variable).permit(:target_id, :env_name, :env_value)
    end
  end
end
