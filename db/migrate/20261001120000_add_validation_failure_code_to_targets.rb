class AddValidationFailureCodeToTargets < ActiveRecord::Migration[8.1]
  def change
    add_column :targets, :validation_failure_code, :string
  end
end
