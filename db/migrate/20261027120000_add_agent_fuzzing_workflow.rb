# frozen_string_literal: true

class AddAgentFuzzingWorkflow < ActiveRecord::Migration[8.0]
  def change
    add_column :scans, :agent_fuzzing, :boolean, default: false, null: false

    create_table :agent_fuzzing_runs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :scan, null: false, foreign_key: true
      t.references :target, null: false, foreign_key: true
      t.references :source_report, null: false, foreign_key: { to_table: :reports }, index: { unique: true }
      t.integer :status, default: 0, null: false
      t.string :outcome
      t.jsonb :budget, default: {}, null: false
      t.jsonb :seeds, default: [], null: false
      t.jsonb :plan, default: [], null: false
      t.jsonb :trials, default: [], null: false
      t.jsonb :findings, default: [], null: false
      t.string :playbook_revision
      t.text :error_message
      t.timestamps
    end


    add_index :scans, :agent_fuzzing
  end
end
