-- V1124 (W6-C + W7): 只登记不搬移。
--
-- 1) W6-C: fn_imported_business_document / fn_imported_business_document_row 声明高 COST。
--    W1(V1120) 后读取路径已经过登记表谓词，权威函数只在写守卫与个别维护路径逐行调用；
--    COST 仍按默认 100 让规划器在「逐行函数 vs 集合反连接」之间误选前者的历史形态
--    (2026-11-07 调研: 反连接曾把 190 万行登记表整表哈希)有复发风险。声明高 COST 只
--    影响计划选择，不改变任何求值语义；写路径语义权威不受影响。
--
-- 2) W7: 大表只登记进 data_lifecycle_policies(V954 清册)的 SOFT_ARCHIVE 档案清单，
--    给 B3 接续留锚；本轮不搬移任何数据、不改任何运行时行为。
--      master_record_versions   ~710MB，12 天 +100MB（主档行版本账）
--      production_plan_costs    ~583MB（计划成本快照）
--      legacy_* 导入暂存        合计 ~729MB（一次性导入的中间产物，保留至验收窗口关闭）

ALTER FUNCTION public.fn_imported_business_document(text,uuid) COST 100000;
ALTER FUNCTION public.fn_imported_business_document_row(text,jsonb) COST 100000;

INSERT INTO data_lifecycle_policies
    (policy_key, domain, subject, purpose, retention_contract, term_note,
     tier_path, authoritative_note, housekeeping_task)
VALUES
 ('master_record_versions','主档','master_record_versions 主档行版本账',
  '基础资料行级变更历史的在线证据(谁在何时把哪一行改成什么)',
  'SOFT_ARCHIVE','只登记不搬移(2026-11-08)：在线留存；搬移/分层方案待 B3 接续设计并验收后另走前向迁移',
  NULL,'行版本以业务表当前值为权威；本表是只增证据','(待定：主档版本归档任务)'),
 ('production_plan_costs','生产','production_plan_costs 计划成本快照',
  '生产计划的成本构成快照，供计划对比与事后核算',
  'SOFT_ARCHIVE','只登记不搬移(2026-11-08)：随计划保留；分层口径待 B3 接续设计',
  NULL,'成本权威在财务入账事实，本表为计划侧快照','(待定：计划成本归档任务)'),
 ('legacy_import_staging','导入','legacy_* 导入暂存表(合计)',
  '旧系统一次性导入的中间暂存与对照产物',
  'SOFT_ARCHIVE','只登记不搬移(2026-11-08)：保留至导入验收窗口正式关闭；届时按清册逐表处置。暂存表本身不在 imported_document_registry(V1120) 登记范围，清理不触碰登记表；清理批次前后各跑一次 V1120 登记对拍守卫(32 表 EXCEPT=0)作双保险，增量导入/修复仍按 V1120 头注同事务重算登记',
  NULL,'业务权威已在正式业务表；暂存表只作对照与补数来源','(待定：导入暂存清理任务)')
ON CONFLICT (policy_key) DO NOTHING;
