class AddThreatVariantIndexesConcurrently < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    cleanup_duplicate_threat_variants

    unless index_exists?(:threat_variants, [ :probe_id, :prompt ], name: "index_threat_variants_on_probe_and_prompt")
      add_index :threat_variants, [ :probe_id, :prompt ], unique: true,
                name: "index_threat_variants_on_probe_and_prompt",
                algorithm: :concurrently
    end

    unless index_exists?(:threat_variants, :prompt, name: "index_threat_variants_on_prompt")
      add_index :threat_variants, :prompt,
                name: "index_threat_variants_on_prompt",
                algorithm: :concurrently
    end
  end

  def down
    remove_index :threat_variants, name: "index_threat_variants_on_prompt", if_exists: true
    remove_index :threat_variants, name: "index_threat_variants_on_probe_and_prompt", if_exists: true
  end

  private

  def cleanup_duplicate_threat_variants
    duplicates = execute(<<~SQL).to_a
      SELECT probe_id, prompt, COUNT(*) AS cnt
      FROM threat_variants
      GROUP BY probe_id, prompt
      HAVING COUNT(*) > 1
    SQL

    return if duplicates.empty?

    say "Found #{duplicates.size} duplicate threat_variant groups — keeping newest, removing rest"

    execute(<<~SQL)
      UPDATE probe_results
      SET threat_variant_id = keeper.id
      FROM (
        SELECT DISTINCT ON (probe_id, prompt) id, probe_id, prompt
        FROM threat_variants
        ORDER BY probe_id, prompt, created_at DESC
      ) AS keeper
      WHERE probe_results.threat_variant_id IN (
        SELECT tv.id FROM threat_variants tv
        WHERE tv.probe_id = keeper.probe_id AND tv.prompt = keeper.prompt AND tv.id != keeper.id
      )
    SQL

    execute(<<~SQL)
      DELETE FROM threat_variants
      WHERE id NOT IN (
        SELECT DISTINCT ON (probe_id, prompt) id
        FROM threat_variants
        ORDER BY probe_id, prompt, created_at DESC
      )
    SQL
  end
end
