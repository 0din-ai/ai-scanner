class AddExecutionTokenToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :execution_token, :uuid
  end
end
