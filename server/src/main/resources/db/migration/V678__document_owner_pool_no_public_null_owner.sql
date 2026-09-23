-- =====================================================================
-- V678：单据对象范围——空归属不再全员可读，系统生成单据显式声明系统池(ADR-109)
-- =====================================================================
-- 背景(permissions-10)：DocumentAccessPolicy 曾把 maker_id / owner_employee_id 为空的单据
--   当作「全员可读」，委外发料计划在财务批准委外订货后自动生成的发料草稿又被故意写成
--   空归属，于是所有持委外发料查看权的部门(综合营销、轨道、仓储、总经办)都能看到全部
--   系统草稿，不受 subcontract:view:all 约束。
-- 本迁移：
--   1) subcontract_material_issues.owner_pool：系统生成、按岗位办理的草稿显式声明所属池
--      (WAREHOUSE_SUBCONTRACT_OUTBOUND = 仓库委外出仓，持 subcontract_outbound:view 的人可读、
--      持出仓执行权的人可办)，不再靠空归属；池单据没有个人归属人。
--   2) 历史上由发料计划生成、仍是空归属的草稿(挂着计划行)归入该池；其余空归属单据
--      (迁移来的历史单)服务端改为只对全量范围可见(fail closed)。
-- 应用层同步删除「归属为空即公开」分支与 nativeReadScopeWithLegacySentinel。
-- =====================================================================

ALTER TABLE subcontract_material_issues
    ADD COLUMN owner_pool TEXT;

ALTER TABLE subcontract_material_issues
    ADD CONSTRAINT subcontract_material_issues_owner_pool_chk
        CHECK (owner_pool IS NULL OR owner_pool = 'WAREHOUSE_SUBCONTRACT_OUTBOUND'),
    ADD CONSTRAINT subcontract_material_issues_pool_has_no_maker_chk
        CHECK (owner_pool IS NULL OR maker_id IS NULL);

COMMENT ON COLUMN subcontract_material_issues.owner_pool IS
    '系统池归属：WAREHOUSE_SUBCONTRACT_OUTBOUND=财务批准委外订货后系统生成、由仓库委外出仓办理的发料草稿(无个人归属人)；为空表示按 maker_id 个人归属';

UPDATE subcontract_material_issues issue
SET owner_pool = 'WAREHOUSE_SUBCONTRACT_OUTBOUND'
WHERE issue.maker_id IS NULL
  AND EXISTS (
      SELECT 1
      FROM subcontract_material_issue_items item
      WHERE item.issue_id = issue.id
        AND item.plan_item_id IS NOT NULL);
