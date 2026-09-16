-- =====================================================================
-- V590 2026-09-15 货品归属「仓库 / 生产车间」单一事实源收敛
-- =====================================================================
-- 用户口径（2026-09-15 拍板）：货品资料表上的归属字段是唯一事实源——
--   1. 任何展示（物料分析、即时库存、货品资料）一律读货品表字段，不再有
--      第二条「实时算一遍」的展示链路；
--   2. 归属仓 goods.owning_warehouse_id(V587)：任何入库（StockService
--      .recordMovement 的 DIR_IN，覆盖采购/委外/完工/调拨/退料/盘盈/手工单
--      全部入库路径）自动回写为最新入库仓——应用层同步，见 StockService；
--   3. 归属生产车间 + 归属车间负责人：原 production_goods_workshop_preferences
--      (V192 建、V488 补负责人) 的「货品 → 车间 + 负责人」学习语义整体搬进
--      货品表两列，偏好表废弃删除；学习写入（排产确认/车间改派）与预填读
--      改走 goods 列（ProductionGoodsWorkshopPreferenceService 同步改造）。
--
-- 本迁移只搬数据、删表、同步清空函数；两条自动回写都是代码行为，无数据迁移。
-- Excel「所属仓库」回填仍走 import_product_lists.py 第 3 段（只填空），
-- 归属车间不经 Excel，由排产操作自动学习。
--
-- 搬迁：偏好表每货品唯一行（uq_prod_goods_workshop_pref_goods），目标列新建
--   为空，直接整行搬入（车间列非空、负责人列可空）。goods 带审计/行触发器，
--   UPDATE 排队触发器事件后 PostgreSQL 拒绝再 ALTER goods——列/索引/FK 全部
--   放在 UPDATE 之前（V259/V587 的顺序规矩）。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS owning_workshop_department_id UUID
        REFERENCES departments(id) ON DELETE RESTRICT;

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS owning_responsible_employee_id UUID
        REFERENCES employees(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_goods_owning_workshop
    ON goods(owning_workshop_department_id)
    WHERE owning_workshop_department_id IS NOT NULL;

UPDATE goods g
SET owning_workshop_department_id = preference.workshop_department_id,
    owning_responsible_employee_id = preference.responsible_employee_id
FROM production_goods_workshop_preferences preference
WHERE preference.goods_id = g.id;

COMMENT ON COLUMN goods.owning_workshop_department_id IS
    '归属生产车间(departments.id，可空)：这批货平时归哪个车间生产的归属。由排产确认/车间改派自动学习回写（V590 起原 production_goods_workshop_preferences 学习语义搬入货品表）。';
COMMENT ON COLUMN goods.owning_responsible_employee_id IS
    '归属车间负责人(employees.id，可空)：与归属车间一起学习的最近一次人工选择（V488 语义，V590 搬入货品表）。';

DROP TABLE production_goods_workshop_preferences;

-- 清空函数孪生同步（V474 同款「读已安装定义 + 锚点替换」失败关闭补丁）：
-- 偏好表已删，business_data_reset 策略清单里的 PRESERVE 行必须一并移除，
-- 否则清空时「策略表 vs 实存表」目录核对失败关闭、拒绝执行。
-- needle 单行无换行符，不受迁移文件 CRLF/LF 差异影响（V588 教训）。
DO $$
DECLARE definition TEXT;
        needle TEXT := '(''production_goods_workshop_preferences'', ''PRESERVE''),';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition) = 0 THEN
        RAISE EXCEPTION 'V590 cannot drop retired preference policy row from business_data_reset';
    END IF;
    definition := replace(definition, needle, '');
    EXECUTE definition;
END;
$$;
