-- V488 货品车间偏好补「负责人」记忆（2026-09-06）
--
-- 背景：下达车间（计划预填）此前只记忆车间（production_goods_workshop_preferences，
-- V192），负责人每次都从组织树带出车间主管——用户手工选过的负责人不会被记住，
-- 表现为「明明操作过一次还是不自动显示」。本迁移为偏好表补
-- responsible_employee_id，正式排产确认/车间改派时一并学习最近一次人工选择，
-- 预填时与车间一起带出（车间变更时整体跟随、同车间未选时保留旧记忆）。
-- 存量回填：与已学习车间一致的最近一次确认执行段负责人。

ALTER TABLE production_goods_workshop_preferences
    ADD COLUMN responsible_employee_id uuid REFERENCES employees(id) ON DELETE RESTRICT;

UPDATE production_goods_workshop_preferences preference
SET responsible_employee_id = backfill.worker,
    updated_at = now()
FROM (
    SELECT DISTINCT ON (segment.product_goods_id)
           segment.product_goods_id,
           segment.workshop_department_id,
           segment.responsible_employee_id AS worker
    FROM production_execution_segments segment
    WHERE segment.workshop_department_id IS NOT NULL
      AND segment.responsible_employee_id IS NOT NULL
      AND segment.is_deleted = FALSE
    ORDER BY segment.product_goods_id, segment.created_at DESC
) backfill
WHERE backfill.product_goods_id = preference.goods_id
  AND backfill.workshop_department_id = preference.workshop_department_id;
