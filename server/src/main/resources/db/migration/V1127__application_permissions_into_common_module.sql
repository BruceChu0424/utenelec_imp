-- =====================================================================
-- V1127：「我的申请」自助码归入「常用模块」并对齐自助码授权策略
-- =====================================================================
-- 背景（两点，同属我的申请自助码归位）：
--   1) V1001 新增的五个自助码（填写申请×4 + 查看申请记录）当时挂在新一级模块
--      「常用功能」下。该模块不在 MODULE_ORDER（DepartmentPermissionAdminService）里，
--      权限管理页（按员工/按部门/全员基础包，含每组的全选勾选）把它排到目录最尾，
--      与工作台自助卡的权限入口「常用模块」(V831/V925) 脱节。本迁移把五个码归入
--      「常用模块」，子类「我的申请」按工作台卡片顺序（公司资料库→我的申请→工资条）
--      以 sort_order 20/21 落在资料库(15)与报销(30)之间；「常用功能」分组清空后消失。
--   2) V1001 把申请族全部码一刀切设为 INDIVIDUAL_ONLY，低风险的填写/查看码也被卷入，
--      于是全员基础包视图按 baselineEligible（=可随批量，排除 INDIVIDUAL_ONLY）把它们
--      整个过滤掉——管理员想给全员开通申请入口时在基础包里连勾都勾不了。自助码的
--      既有口径是 NORMAL（报销 expense:apply / 工资条 payroll:view:self / 意见箱
--      suggestion:submit 均 NORMAL 且 baseline=true）：本迁移把五个码对齐为 NORMAL，
--      基础包/部门矩阵/负责人转授恢复可操作；baseline 默认仍为 false，是否全员开通
--      由管理员在全员基础包里自行勾选，不静默改变任何人的有效权限。
-- 口径：
--   1) application:apply:supplier_payment 仍归「采购管理」且维持 INDIVIDUAL_ONLY
--      （V1001 原口径：采购侧专码、按人开通）；各级审批码（approve:*/receive/pay/
--      link_finance）同样维持 INDIVIDUAL_ONLY 不动；
--   2) 除 module/sort_order/grant_policy 外不动 code/name/description/baseline/
--      授权行/页面授权面（permission_surfaces 的 common.applications 原样）；
--   3) module 归类与授权策略的权威仍在迁移链上（V228 归类约定、ADR-109 策略口径：
--      后续改动在各自迁移里直接写）。
-- =====================================================================

UPDATE permissions
SET module = '常用模块', sort_order = 20, grant_policy = ARRAY['NORMAL']::text[]
WHERE code IN ('application:apply', 'application:apply:travel',
               'application:apply:payment', 'application:apply:prepayment')
  AND module = '常用功能';

UPDATE permissions
SET module = '常用模块', sort_order = 21, grant_policy = ARRAY['NORMAL']::text[]
WHERE code = 'application:view' AND module = '常用功能';

-- 失败关闭：临时模块必须清空；五个码必须按 (码, sort) 就位且策略为 NORMAL、
-- baseline 维持默认关闭；供应商付款码不得被卷入（归类与策略都保持原口径）。
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM permissions WHERE module = '常用功能') THEN
        RAISE EXCEPTION 'V1127 module 常用功能 must be empty after moving 我的申请 codes into 常用模块';
    END IF;
    IF (SELECT count(*) FROM permissions
        WHERE (code, sort_order) IN (
            ('application:apply', 20),
            ('application:apply:travel', 20),
            ('application:apply:payment', 20),
            ('application:apply:prepayment', 20),
            ('application:view', 21))
          AND module = '常用模块' AND category = '我的申请'
          AND grant_policy = ARRAY['NORMAL']::text[] AND NOT baseline) <> 5 THEN
        RAISE EXCEPTION 'V1127 the five application self-service codes must sit in 常用模块/我的申请 as NORMAL policy with baseline off';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM permissions
                   WHERE code = 'application:apply:supplier_payment'
                     AND module = '采购管理' AND category = '我的申请'
                     AND grant_policy = ARRAY['INDIVIDUAL_ONLY']::text[]) THEN
        RAISE EXCEPTION 'V1127 supplier payment apply code must stay in 采购管理/我的申请 as INDIVIDUAL_ONLY';
    END IF;
END $$;
