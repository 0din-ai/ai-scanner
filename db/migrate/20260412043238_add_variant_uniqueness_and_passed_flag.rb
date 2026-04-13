class AddVariantUniquenessAndPassedFlag < ActiveRecord::Migration[8.1]
  def change
    add_column :probe_results, :any_detector_passed, :boolean, default: false, null: false
  end
end
