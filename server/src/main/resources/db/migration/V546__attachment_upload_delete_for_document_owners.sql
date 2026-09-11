-- V546 附件上传/删除权限扩授到单据归属部门 + 附件权限归类「通用 → 附件」（2026-09-10）
--
-- 背景：用户要求「新建销售订货单页在保存前就能上传附件；财务审核页可看；其他有上传处同样」。
-- 审计发现 attachment:upload / attachment:delete 自 V280（attachment:manage）→ V328（拆分）
-- 起只挂在 DEPT_FIN / DEPT_HR，而销售/采购/委外/仓库/计划/生产/品检等单据归属部门虽然
-- 页面已接共享附件区（BusinessAttachmentSection 叠加 attachment:upload 才显示「上传」），
-- 员工却永远看不到上传按钮。对象级范围仍由各 ownerType 的 AttachmentOwnerAccessPolicy 终审
-- （草稿/退回可管理，提交审核或生效后只读），本迁移只补通用功能门槛。
--
-- 同时 V328 把 attachment:* 归在「人事行政 → 附件」（当时只有员工档案入口），现已是全模块
-- 共用能力，改归「通用 → 附件」（后端 MODULE_ORDER 追加「通用」，排在系统管理之后）。
-- 权限目录写入由 V135 触发器推进 authorization_state.epoch，在线会话按版本机制即时生效。
--
-- 幂等：UPDATE 带条件；INSERT … ON CONFLICT DO NOTHING；未知部门编码由 JOIN 自然跳过。
-- 同步文档：docs/数据迁移/144-V546附件上传删除权限扩授.md、docs/03-页面/权限管理页.md。

-- ① 附件权限目录归类：人事行政/附件 → 通用/附件（含已停用的历史复合码，保持同组）。
UPDATE permissions
SET module = '通用', category = '附件'
WHERE code LIKE 'attachment:%'
  AND (module IS DISTINCT FROM '通用' OR category IS DISTINCT FROM '附件');

-- ② 扩授 attachment:upload + attachment:delete 给单据归属部门（在职、未删除）。
--    销售：DEPT_SALES / DEPT_RAIL / DEPT_NEWMEDIA / SALE_G1..G4 / RAIL_MUDUO / RAIL_ZHIQIAN
--    供应链：DEPT_PMC / SUB_PURCHASE / SUB_WH / SUB_PLAN
--    生产与品检：DEPT_PROD / DEPT_QA / QA_OUT / QA_TEST
--    管理层与中心：GM / FIN_CENTER / MKT_CENTER / MFG_CENTER
--    （DEPT_FIN / DEPT_HR 已有，ON CONFLICT 幂等跳过。）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p
  ON p.code IN ('attachment:upload', 'attachment:delete')
 AND p.active = TRUE
WHERE d.is_deleted = FALSE
  AND d.code IN (
      'DEPT_SALES', 'DEPT_RAIL', 'DEPT_NEWMEDIA',
      'SALE_G1', 'SALE_G2', 'SALE_G3', 'SALE_G4',
      'RAIL_MUDUO', 'RAIL_ZHIQIAN',
      'DEPT_PMC', 'SUB_PURCHASE', 'SUB_WH', 'SUB_PLAN',
      'DEPT_PROD', 'DEPT_QA', 'QA_OUT', 'QA_TEST',
      'GM', 'FIN_CENTER', 'MKT_CENTER', 'MFG_CENTER'
  )
ON CONFLICT (department_id, permission_id) DO NOTHING;
