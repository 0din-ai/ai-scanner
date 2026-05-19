# frozen_string_literal: true

class AddFailureMetadataToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :failure_code, :string
    add_column :reports, :failure_message, :text
    add_column :reports, :failure_details, :jsonb, default: {}, null: false

    add_index :reports, :failure_code
  end
end
