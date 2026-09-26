-- ActualOutputSupplementController(#29 引入)与前端生产日报编辑页的 Perm 常量都引用
-- production_plan:create，但该码从未播种进 permissions 目录：
-- PreAuthorizeCodesAreActiveContractTest / PermissionCatalogBidirectionalContractTest
-- 双向契约在 backend-db 全链里双双拦截。补齐目录使其成为可授予的活码
-- (语义：可直接创建生产计划/补登记计划，区别于走分析链路的
-- production_material_analysis:create 与车间侧窄口 production_execution:request_supplement_plan)。
INSERT INTO permissions(code, name, module, category, sort_order, action_type, description, grant_policy)
VALUES ('production_plan:create', '创建生产计划', '生产管理', '生产计划', 402, 'CREATE',
        '直接创建/补登记生产计划（含日报实际产出补登记计划）；正式新增计划仍须走物料分析',
        ARRAY['NORMAL']::text[])
ON CONFLICT (code) DO NOTHING;

-- 按钮所在页面：生产日报编辑页的「补计划」入口。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
CROSS JOIN permissions permission
WHERE surface.surface_key = 'production.daily-report'
  AND permission.code = 'production_plan:create'
ON CONFLICT DO NOTHING;

-- SchemaIndexHygieneContractTest: V701 的证明表漏了 supplement_plan_item_id 领头索引
-- (守恒触发器与服务查询按它回查子表)。
CREATE INDEX idx_actual_output_supplement_proofs_plan_item
    ON production_actual_output_supplement_proofs (supplement_plan_item_id);

-- HotTableTriggerHygieneContractTest: V704 的完工守卫触发器是热表上的延迟约束触发器,
-- UPDATE 起跳没带 WHEN(JPA/整行更新会把所有列塞进 SET 清单, UPDATE OF 挡不住排队)。
-- 按 V692 口径拆 INSERT 与 _upd(WHEN 只在 fqty 真变时排队)。
DROP TRIGGER trg_production_plan_finished_guard ON production_plan_items;
CREATE CONSTRAINT TRIGGER trg_production_plan_finished_guard
    AFTER INSERT ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_production_plan_actual_finished();
CREATE CONSTRAINT TRIGGER trg_production_plan_finished_guard_upd
    AFTER UPDATE OF fqty ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.fqty IS DISTINCT FROM NEW.fqty)
    EXECUTE FUNCTION fn_assert_production_plan_actual_finished();
