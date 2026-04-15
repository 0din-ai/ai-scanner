# frozen_string_literal: true

class BackfillAndEnforceNotNullOnProbeResultAttempts < ActiveRecord::Migration[8.0]
  CONSTRAINT_NAME = "chk_probe_results_attempts_not_null"

  def up
    add_check_constraint :probe_results,
      "attempts IS NOT NULL",
      name: CONSTRAINT_NAME,
      validate: false

    execute "UPDATE probe_results SET attempts = '[]'::json WHERE attempts IS NULL"

    validate_check_constraint :probe_results, name: CONSTRAINT_NAME
    change_column_null :probe_results, :attempts, false
    remove_check_constraint :probe_results, name: CONSTRAINT_NAME
  end

  def down
    change_column_null :probe_results, :attempts, true
    remove_check_constraint :probe_results, name: CONSTRAINT_NAME, if_exists: true
  end
end
