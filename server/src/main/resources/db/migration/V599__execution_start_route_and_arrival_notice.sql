-- V599 开工路线确认门控与到货进展通知（ADR-091）。
--
-- 背景(2026-09-17 用户口径)：
--   「应该先让车间的人先确定路线，只有把路线确定了先，才好去卡流程、解锁啥的。」
--   「待领料那里的下一步改成路线确认。」
--   「物料分批到的……给对应的车间弹窗：某某物料到了 100 个，还差什么物料，
--     或者物料已支持开工，去领料开工啥的。」
--
-- 三件事：① 段上两列记录已确认的开工路线；② 齐套自动提升按路线放行(未确认/分批/未开工的持续生产
-- 都不再被系统替车间做决定)；③ 事件动作白名单加 ROUTE_CONFIRMED(到货通知本身复用既有 notices
-- 聚合，不加表)。不新增业务表、不改任何既有业务行的语义——回填后所有存量段都视为已确认，
-- 升级零摩擦。

-- ============ ① 段上的开工路线 ============
-- start_route：NULL=尚未确认(所有开工侧动作被拒，等车间显式选路)；
--   FULL_KIT=齐套生产(默认，等全部子件到齐一次领料)；
--   BATCH=分批生产(按可齐套上限拆子批，ADR-078)；
--   CONTINUOUS=持续生产(同车间直送到一批投一批，ADR-089/V595)。
-- route_confirmed_at：最后一次确认/改选时间；操作人记在事件账 ROUTE_CONFIRMED 的 created_by。
ALTER TABLE production_execution_segments
    ADD COLUMN start_route TEXT,
    ADD COLUMN route_confirmed_at TIMESTAMPTZ;

ALTER TABLE production_execution_segments
    ADD CONSTRAINT production_execution_segments_start_route_check
        CHECK (start_route IS NULL
               OR start_route IN ('FULL_KIT', 'BATCH', 'CONTINUOUS'));

COMMENT ON COLUMN production_execution_segments.start_route IS
    '已确认的开工路线(V599)：NULL=待车间确认(开工侧动作全被拒)；FULL_KIT=齐套生产；BATCH=分批生产(ADR-078)；CONTINUOUS=持续生产(ADR-089)';
COMMENT ON COLUMN production_execution_segments.route_confirmed_at IS
    '开工路线最后一次确认时间(V599)；操作人见事件账 ROUTE_CONFIRMED';

-- ============ ② 存量回填：升级零摩擦 ============
-- 已按持续生产开工的段回填 CONTINUOUS；其余段回填 FULL_KIT——但分批谱系的「剩余段」
-- 例外回填 BATCH：它还要继续等下一批拆批(V599 后分批提交要求 route=BATCH，回填成
-- FULL_KIT 会让在途分批链断档)。批次段=每一批本身就是一次小齐套，回填 FULL_KIT。
UPDATE production_execution_segments segment
SET start_route = CASE
        WHEN segment.continuous_supply THEN 'CONTINUOUS'
        WHEN EXISTS (SELECT 1 FROM production_execution_segment_splits split
                     WHERE split.remaining_segment_id = segment.id) THEN 'BATCH'
        ELSE 'FULL_KIT'
    END,
    route_confirmed_at = now()
WHERE start_route IS NULL;

-- ============ ③ 齐套自动提升按路线放行 ============
-- 唯一口径：FULL_KIT 放行(旧行为)；BATCH 抑制(根段等车间拆批，批次段/剩余段各自提升)；
-- CONTINUOUS 在 start-continuous 置位 continuous_supply 前抑制(保住 WAITING，持续生产入口
-- 不被仓库料先到顶掉——V595 竞态关闭)，置位后恢复(混合链仓库需求照旧自动提升)；
-- NULL 抑制(系统不替车间选路，确认 FULL_KIT 时由服务端同事务补跑提升)。
CREATE FUNCTION fn_execution_route_allows_auto_promote(p_segment UUID)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT CASE
            WHEN segment.start_route IS NULL THEN FALSE
            WHEN segment.start_route = 'FULL_KIT' THEN TRUE
            WHEN segment.start_route = 'BATCH' THEN FALSE
            ELSE COALESCE(segment.continuous_supply, FALSE)
        END
        FROM production_execution_segments segment
        WHERE segment.id = p_segment
          AND segment.is_deleted = FALSE),
        FALSE);
$$;

-- 改路线的尺子(与 ADR-078「未动过才可拆」同源)：仅 WAITING 且没有任何领料单、报工、供给钉、
-- 预留的段可以重新确认路线；一旦动过或离开 WAITING，路线冻结。
CREATE FUNCTION fn_can_change_execution_route(p_segment UUID)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
        WHERE segment.id = p_segment
          AND segment.status = 'WAITING'
          AND NOT segment.is_deleted
          AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents document
              WHERE document.execution_segment_id = segment.id)
          AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report
              WHERE report.execution_segment_id = segment.id)
          AND NOT EXISTS(SELECT 1 FROM production_material_demands demand
              JOIN production_material_supply_pegs peg ON peg.demand_id = demand.id
              WHERE demand.execution_segment_id = segment.id)
          AND NOT EXISTS(SELECT 1 FROM production_material_demands demand
              JOIN stock_reservations reservation ON reservation.demand_id = demand.id
              WHERE demand.execution_segment_id = segment.id));
$$;

COMMENT ON FUNCTION fn_execution_route_allows_auto_promote(UUID) IS
    '齐套自动提升是否对该段放行(V599)：FULL_KIT=放行；BATCH/未确认=抑制；CONTINUOUS=持续生产开工置位后放行';
COMMENT ON FUNCTION fn_can_change_execution_route(UUID) IS
    '能否重新确认开工路线(V599)：仅 WAITING 且未动过(无领料单/报工/供给钉/预留)';

-- ============ ⑤ 到货命中查询的索引(性能) ============
-- 到货进展卡的缺口查询按 demand_id 反查领料行：既有唯一索引前导 package_id，逐需求顺序扫描
-- 会被每次到货 × 最多 30 段放大。(对抗复审 S1：goods_id 前导的需求索引 V186
-- idx_pmd_where_used_all_evidence 已覆盖且带 INCLUDE，不再重复建。)
CREATE INDEX idx_planning_package_document_items_demand
    ON production_planning_package_document_items(demand_id)
    WHERE document_type = 'DRAW';

-- ============ ⑥ 执行段事件：新增「确认路线」动作 ============
-- 与 V470/V595 同法整条重建 CHECK(动作清单是白名单)；既有事件行一个字节不动。
ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE',
            'REOPEN_COMPLETION', 'RELEASE_DEFER',
            'AUTO_START_ON_REPORT', 'RECHECK_MATERIAL', 'DRAW_REQUEST',
            'START_CONTINUOUS', 'ROUTE_CONFIRMED'
        ));
