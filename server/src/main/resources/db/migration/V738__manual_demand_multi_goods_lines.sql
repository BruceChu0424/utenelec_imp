-- V738 手工需求单多货品 (ADR-130, 2026-09-27)。
--
-- 背景: 手工需求(返工/试制/样品/备库/其他)改成像一张小销售订单: 一个需求编号 = 一张手工需求单,
-- 下挂多个货品行, 与所选销售订单行一起联合分析。V234 建、V529 重建的全局唯一索引
-- uq_production_material_analysis_manual_source_ref 把 (来源类型, 需求编号) 限成全库只有一行,
-- 一个需求编号因此只能挂一个货品。
--
-- 本迁移:
-- 1. 删掉旧索引, 按来源分成两条部分唯一索引:
--    - 系统来源(自制备料 MAKE_COMPONENT / 委外自制 SUBCONTRACT_MAKE / 共享制造 AGGREGATE_MAKE /
--      委外前置 SC-PREP)仍按 (来源类型, 编号) 全局唯一。其中只有 MAKE_COMPONENT 与 SUBCONTRACT_MAKE
--      在 MaterialAnalysisCommandService 生成编号前做「编号可用」探测并换码重试, 依赖此索引;
--      AGGREGATE_MAKE(共享制造 日期+批次号前 8 位) 与 SC-PREP(SC-PREP:订货行 id) 靠构造保证唯一,
--      没有探测, 由此索引在数据库层兜底。SC-ORDER 直接委外准备维持 V529 的排除。
--    - 手工来源五类按 (来源类型, 编号, 货品, 颜色, 单位) 唯一: 同一编号下可有多个货品, 同一货品只占一行。
-- 2. 「一个手工需求编号只属于一份物料分析」(ADR-029) 改由触发器守住: 先按与服务端
--    (MaterialAnalysisService#lockSourceIdentities) 完全相同的键文本取事务级 advisory 锁, 再查同类型同编号
--    (忽略大小写与首尾空格) 是否已挂在另一份分析上, 有就拒绝 (SQLSTATE 23505, 与旧唯一索引同一错误码)。
--    production_material_analysis_items 是热表, 按 ADR-106/V674 拆成 INSERT 与 _upd 两条,
--    UPDATE 只在分析/类型/编号/删除标记真变了时起跳; 两条都 ENABLE ALWAYS(与旧唯一索引一样不受复制角色影响)。
-- 新规则比旧索引宽 (旧规则下每个编号全库只有一行), 存量数据不可能违反, 不回填。不加表不加列。

DROP INDEX uq_production_material_analysis_manual_source_ref;

CREATE UNIQUE INDEX uq_production_material_analysis_system_source_ref
    ON production_material_analysis_items(source_type, lower(btrim(source_ref)))
    WHERE is_deleted = FALSE
      AND source_type NOT IN ('SALES_ORDER_ITEM','REWORK','TRIAL','SAMPLE','STOCK','OTHER')
      AND NOT (source_type = 'SUBCONTRACT_PREPARATION' AND source_ref LIKE 'SC-ORDER:%');

CREATE UNIQUE INDEX uq_production_material_analysis_manual_source_line
    ON production_material_analysis_items(
        source_type, lower(btrim(source_ref)), goods_id, color_id, unit_id
    ) NULLS NOT DISTINCT
    WHERE is_deleted = FALSE
      AND source_type IN ('REWORK','TRIAL','SAMPLE','STOCK','OTHER');

CREATE FUNCTION fn_guard_manual_demand_single_analysis() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- 与服务端取的是同一把锁 (键文本逐字一致), 并发的同编号请求在这里排队, 后到者能看见先到者已提交的行。
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'MATERIAL-ANALYSIS-MANUAL-REF:' || NEW.source_type || '|' || lower(btrim(NEW.source_ref)), 0));
    -- 条件里写死手工五类, 规划器才能用上 uq_production_material_analysis_manual_source_line。
    IF EXISTS (
        SELECT 1
        FROM production_material_analysis_items other
        WHERE other.is_deleted = FALSE
          AND other.source_type IN ('REWORK','TRIAL','SAMPLE','STOCK','OTHER')
          AND other.source_type = NEW.source_type
          AND lower(btrim(other.source_ref)) = lower(btrim(NEW.source_ref))
          AND other.analysis_id <> NEW.analysis_id
          AND other.id <> NEW.id) THEN
        RAISE EXCEPTION '需求编号 % 已属于另一份物料分析, 同一需求编号只能在一份物料分析里; 请换一个需求编号',
            btrim(NEW.source_ref) USING ERRCODE = '23505';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_guard_manual_demand_single_analysis
    BEFORE INSERT ON production_material_analysis_items
    FOR EACH ROW WHEN (NEW.source_type IN ('REWORK','TRIAL','SAMPLE','STOCK','OTHER') AND NOT NEW.is_deleted)
    EXECUTE FUNCTION fn_guard_manual_demand_single_analysis();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_guard_manual_demand_single_analysis;
CREATE TRIGGER trg_guard_manual_demand_single_analysis_upd
    BEFORE UPDATE ON production_material_analysis_items
    FOR EACH ROW WHEN ((OLD.analysis_id, OLD.source_type, OLD.source_ref, OLD.is_deleted)
        IS DISTINCT FROM (NEW.analysis_id, NEW.source_type, NEW.source_ref, NEW.is_deleted)
        AND NEW.source_type IN ('REWORK','TRIAL','SAMPLE','STOCK','OTHER') AND NOT NEW.is_deleted)
    EXECUTE FUNCTION fn_guard_manual_demand_single_analysis();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_guard_manual_demand_single_analysis_upd;
