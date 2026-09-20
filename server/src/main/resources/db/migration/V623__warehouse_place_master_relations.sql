-- V623: warehouse/goods/color placement is a multidimensional master relation.
-- Retire history-on-read by retaining only provable, unambiguous legacy defaults.
-- Never overwrite an existing relation or a newer explicit goods-master change.
CREATE INDEX IF NOT EXISTS idx_finished_arrival_actor_recent
    ON production_finished_arrival_registrations(created_by, created_at DESC, id DESC);

-- The retired account-wide shelf value had no goods/color/warehouse identity.
-- Preserve the user's last-selected warehouse and every unrelated UI setting.
UPDATE user_preferences
SET pref_value = pref_value - 'stockPlace', updated_at = now()
WHERE pref_key = 'warehouse.arrivalFill'
  AND jsonb_typeof(pref_value) = 'object' AND pref_value ? 'stockPlace';

WITH batches AS (
    SELECT registration.id, registration.warehouse_id, registration.created_at,
           registration.created_by, actor.employee_id AS selected_employee_id,
           report_item.goods_id, report_item.color_id,
           MIN(BTRIM(item.place_snapshot)) AS place,
           COUNT(DISTINCT NULLIF(BTRIM(item.place_snapshot), '')) AS place_count,
           BOOL_AND(NULLIF(BTRIM(item.place_snapshot), '') IS NOT NULL) AS all_placed
    FROM production_finished_arrival_registrations registration
    JOIN production_finished_arrival_registration_items item
      ON item.registration_id=registration.id AND item.reversal_id IS NULL
    JOIN production_daily_report_items report_item ON report_item.id=item.source_report_item_id
    JOIN goods ON goods.id=report_item.goods_id AND NOT goods.is_deleted
    JOIN users actor ON actor.id=registration.created_by AND actor.employee_id IS NOT NULL
    JOIN warehouses warehouse ON warehouse.id=registration.warehouse_id
      AND NOT warehouse.is_deleted AND NOT warehouse.is_line_side
    WHERE NOT EXISTS (SELECT 1 FROM production_finished_arrival_registration_reversals reversal
                      WHERE reversal.registration_id=registration.id)
      AND NULLIF(BTRIM(goods.stock_place), '') IS NULL
      AND goods.updated_at <= registration.created_at
    GROUP BY registration.id, actor.employee_id, report_item.goods_id, report_item.color_id
), latest AS (
    SELECT DISTINCT ON (warehouse_id, goods_id, color_id) *
    FROM batches
    ORDER BY warehouse_id, goods_id, color_id, created_at DESC, id DESC
)
INSERT INTO warehouse_goods_place_preferences(
    warehouse_id, goods_id, color_id, place, selection_count, version,
    source_kind, source_registration_id, source_iqc_batch_id, source_registered_at,
    last_selected_by, last_selected_at, created_by, updated_by)
SELECT warehouse_id, goods_id, color_id, place, 1, 0,
       'FINISHED_ARRIVAL', id, NULL, created_at,
       selected_employee_id, created_at, created_by, created_by
FROM latest
WHERE place_count=1 AND all_placed AND length(place) BETWEEN 1 AND 100
ON CONFLICT ON CONSTRAINT warehouse_goods_place_preference_dimension_uk DO NOTHING;

COMMENT ON TABLE warehouse_goods_place_preferences IS
    '仓库×货品×颜色主档建议库位关系；保留真实学习来源，不是库位实物数量或交易历史；读取不再扫描历史单据';
