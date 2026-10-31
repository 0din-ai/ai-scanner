# frozen_string_literal: true

class AddAgentAssessmentArtifacts < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_fuzzing_runs, :execution_token, :string

    create_table :agent_fuzzing_artifacts do |t|
      t.references :company, null: false, foreign_key: true
      t.references :agent_fuzzing_run, null: false, foreign_key: true
      t.string :trial_id, null: false
      t.string :arm, null: false
      t.string :source_digest, null: false, index: { unique: true }
      t.string :receipt_digest, null: false, index: { unique: true }
      t.text :body, null: false
      t.string :body_sha256, null: false
      t.integer :source_reads, default: 0, null: false
      t.integer :receipt_count, default: 0, null: false
      t.datetime :source_read_at
      t.datetime :receipt_at
      t.string :source_request_id
      t.string :receipt_request_id
      t.datetime :expires_at, null: false
      t.datetime :closed_at
      t.timestamps
    end
  end
end
