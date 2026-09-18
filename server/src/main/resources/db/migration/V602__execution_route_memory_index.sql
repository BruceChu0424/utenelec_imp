-- V602: 生产路线记忆——同产品最近一次确认的开工路线索引。
--
-- 背景（2026-09-18 用户口径）：「生产路线要带有记忆，下次默认选择上次选择的」。
-- 车间任务页未确认路线的工单，下拉预填同产品最近一次确认的 start_route
-- （服务端 workshopTasks 投影尾列 suggested_start_route 的派生子查询，
-- ORDER BY route_confirmed_at DESC LIMIT 1），记忆不在当前收窄选项里时前端
-- 回落默认齐套。记忆不另建存储：确认/改选都会刷新 route_confirmed_at，
-- 「上次选择的」天然就是最新一条确认记录，无需回写。
--
-- 本迁移只为该派生子查询建部分索引（每行一次 LIMIT 1 点查）。
-- 对抗复审口径：product_goods_id 前导 + route_confirmed_at DESC 排序键完全
-- 匹配子查询的 WHERE + ORDER BY，部分谓词与子查询过滤同源。

CREATE INDEX idx_execution_segments_route_memory
  ON production_execution_segments (product_goods_id, route_confirmed_at DESC)
  WHERE start_route IS NOT NULL AND is_deleted = FALSE;

COMMENT ON INDEX idx_execution_segments_route_memory IS
    '生产路线记忆点查(V602)：同产品最近一次确认的开工路线（部分索引，与车间任务页 suggested_start_route 子查询同源）';
