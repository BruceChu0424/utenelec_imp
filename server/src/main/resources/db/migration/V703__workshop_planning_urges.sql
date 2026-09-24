-- ADR-117 车间催计划下单子层物料。
--
-- 车间任务缺料时, 服务端按物料分析同一口径(节点「还缺数量」)判断这份缺口是「计划已经安排、
-- 等到货」还是「计划还没下单」。后者车间可以一键催计划: 本表记录每个车间任务当前是否在催、
-- 催了几次、最近一次是谁什么时候催的。计划员下够单(缺口归零)或任务结束后由核对任务办结,
-- 同时撤回发给计划员的待办卡片。
--
-- 一个车间任务同一时刻最多一条「在催」记录; 再催只加次数、刷新最近时间, 不另建行。
-- 本表只是提醒协调状态, 不改任何需求、库存或单据数量。
CREATE TABLE production_planning_urges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id) ON DELETE RESTRICT,
    material_analysis_id UUID NOT NULL REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESOLVED')),
    urge_count INTEGER NOT NULL DEFAULT 1 CHECK (urge_count >= 1),
    -- 最近一次催的时候计划还没下单的物料种数与点名(给计划员的通知正文用, 只是快照)。
    gap_kind_count INTEGER NOT NULL CHECK (gap_kind_count >= 1),
    gap_summary TEXT NOT NULL CHECK (length(btrim(gap_summary)) BETWEEN 1 AND 500),
    first_urged_by UUID NOT NULL REFERENCES users(id),
    first_urged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_urged_by UUID NOT NULL REFERENCES users(id),
    last_urged_by_name TEXT NOT NULL CHECK (length(btrim(last_urged_by_name)) BETWEEN 1 AND 100),
    last_urged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    -- ARRANGED = 计划已下够单(缺口归零); TASK_CLOSED = 任务已完工/取消/不再需要这批料。
    resolution TEXT CHECK (resolution IN ('ARRANGED','TASK_CLOSED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_planning_urge_resolution_shape CHECK (
        (status = 'OPEN' AND resolved_at IS NULL AND resolution IS NULL)
        OR (status = 'RESOLVED' AND resolved_at IS NOT NULL AND resolution IS NOT NULL)),
    CONSTRAINT production_planning_urge_time_order CHECK (last_urged_at >= first_urged_at)
);

-- 一个车间任务同时只能有一条在催记录(并发两次点击落到同一行)。
CREATE UNIQUE INDEX uq_production_planning_urge_open_segment
    ON production_planning_urges(execution_segment_id) WHERE status = 'OPEN';
-- 车间任务详情 / 列表按任务取最近一条; 同时承担外键索引。
CREATE INDEX idx_production_planning_urge_segment
    ON production_planning_urges(execution_segment_id, last_urged_at DESC);
-- 计划侧按物料分析取在催记录、徽章与核对任务按在催扫描。
CREATE INDEX idx_production_planning_urge_analysis
    ON production_planning_urges(material_analysis_id, status);
CREATE INDEX idx_production_planning_urge_open
    ON production_planning_urges(last_urged_at, id) WHERE status = 'OPEN';

COMMENT ON TABLE production_planning_urges IS
    'ADR-117 车间催计划下单子层物料: 每个车间任务最多一条在催记录; 缺口归零或任务结束由核对任务办结。只是提醒协调状态, 不改任何数量。';

-- 协调提醒不挂行级审计: 发起人与时间在行内, 人的操作由请求级语义事件记录(ADR-105 queue 组)。
SELECT fn_audit_track_table('production_planning_urges', 'NONE', 'data_change', false);

-- 清空业务数据时一并清空(与本表所指的车间任务、物料分析同属业务流程数据)。
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V703 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''production_planning_urges'', ''CLEAR'')');
END;
$reset_policy$;
