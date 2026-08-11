-- V211 rd_tasks 转发去重改 goods 级 + 多计划员等待名单 rd_task_forwarders。
-- 背景：原去重键 (order_item_id, goods_id) 对组件转发（order_item_id 为 NULL）完全失效，
-- 且同一组件出现在不同销售订单时重复通知研发。改为按 goods_id 去重（每个组件只通知研发一次），
-- 另用 rd_task_forwarders 记录所有等待该组件的计划员，研发维护好 BOM 后逐个通知。
-- 自包含迁移：建表 → 种子化现存 reporter → 幂等清理重复任务 → 重建唯一索引，应用即生效。

-- 1) 多计划员等待名单表（rd_tasks 同款 Pattern B：纯 JdbcTemplate，不挂 FK/审计触发器，
--    主体审计以 rd_tasks 为准；等待名单随 OPEN 任务查询时 JOIN rd_tasks 自然过滤）。
CREATE TABLE IF NOT EXISTS rd_task_forwarders (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    rd_task_id            uuid NOT NULL,
    reporter_employee_id  uuid NOT NULL,
    order_item_id         uuid,
    source_doc_type       varchar(40),
    source_doc_id         uuid,
    source_doc_no         varchar(64),
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    CONSTRAINT uq_rd_task_forwarders UNIQUE (rd_task_id, reporter_employee_id)
);
CREATE INDEX IF NOT EXISTS idx_rd_task_forwarders_task     ON rd_task_forwarders (rd_task_id);
CREATE INDEX IF NOT EXISTS idx_rd_task_forwarders_reporter ON rd_task_forwarders (reporter_employee_id);

-- 2) 把同 goods 组内所有 OPEN/IN_PROGRESS BOM 任务的 reporter 种子化到该组最早任务（keeper）上，
--    避免下一步去重时丢失非 keeper 任务的 reporter（他们也是等待者，须保留以便完成通知）。
INSERT INTO rd_task_forwarders (rd_task_id, reporter_employee_id, created_at)
SELECT keeper.id, t.reporter_employee_id, COALESCE(t.created_at, now())
FROM rd_tasks t
JOIN LATERAL (
    SELECT k.id
    FROM rd_tasks k
    WHERE k.category = 'BOM' AND k.status IN ('OPEN','IN_PROGRESS') AND k.is_deleted = false
      AND k.goods_id IS NOT NULL AND k.goods_id = t.goods_id
    ORDER BY k.created_at, k.id
    LIMIT 1
) keeper ON true
WHERE t.category = 'BOM' AND t.status IN ('OPEN','IN_PROGRESS') AND t.is_deleted = false
  AND t.goods_id IS NOT NULL
  AND t.reporter_employee_id IS NOT NULL
ON CONFLICT (rd_task_id, reporter_employee_id) DO NOTHING;

-- 3) 幂等清理重复 OPEN/IN_PROGRESS BOM 任务：每 goods 保留最早一条，其余置 CANCELED。
--    幂等：重跑时已 CANCELED 行被 status IN('OPEN','IN_PROGRESS') 排除，rn 重新计算不再命中。
UPDATE rd_tasks t
SET status = 'CANCELED',
    close_note = COALESCE(t.close_note, '去重合并：同货品仅保留最早一条 BOM 转发任务'),
    row_version = t.row_version + 1,
    updated_at = now()
FROM (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY goods_id ORDER BY created_at, id) AS rn
    FROM rd_tasks
    WHERE category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = false
      AND goods_id IS NOT NULL
) ranked
WHERE t.id = ranked.id AND ranked.rn > 1;

-- 4) 重建唯一索引：按 goods_id 去重（每个货品同时只允许一个未完成 BOM 任务）。
--    旧 DONE/CANCELED 行不匹配 WHERE 子句，故「维护后再次缺 BOM」可新建任务。
DROP INDEX IF EXISTS uq_rd_tasks_open_bom;
CREATE UNIQUE INDEX uq_rd_tasks_open_bom ON rd_tasks (goods_id)
    WHERE category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = false;
