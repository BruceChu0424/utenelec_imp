-- V424: 审计日志降噪——系统自动行为不再写入审计日志。
--
-- 背景：V396 的全表触发器覆盖把"系统自动行为"也记进了审计日志：
--   1. 通知体系 4 张表：系统发布通知（如审批通过后自动发布的站内通知）、
--      用户已读状态、知悉确认、祝福回复，都是通知机制自身的数据流，
--      不是人在业务页面上的操作，但在审计日志里占了大量行数；
--   2. 纯系统管道表：业务事件发件箱（通知投递队列）、附件事件发件箱、
--      账户月度流水汇总（报表物化数据）、各类幂等指令表（*_commands），
--      全部由后台任务/框架自动写入，无人工操作含义。
-- 这些行让审计日志变得又多又难读。人工操作仍通过 HTTP 请求覆盖行
-- （UserOperationAuditInterceptor）与业务表触发器行完整留痕。
--
-- 注意：今后如再新增 refresh_audit_trigger_coverage 全表扫描迁移，
-- 必须把下面这些表加入排除清单，否则触发器会被重新挂回。

-- 通知体系：系统/用户在通知机制内部的数据流，不再进审计日志
DROP TRIGGER IF EXISTS trg_audit_notices ON notices;
DROP TRIGGER IF EXISTS trg_audit_notice_user_states ON notice_user_states;
DROP TRIGGER IF EXISTS trg_audit_notice_acknowledgments ON notice_acknowledgments;
DROP TRIGGER IF EXISTS trg_audit_notice_blessings ON notice_blessings;

-- 系统管道：后台任务/框架自动写入，无人工操作含义
DROP TRIGGER IF EXISTS trg_audit_business_outbox ON business_outbox;
DROP TRIGGER IF EXISTS trg_audit_attachment_object_outbox ON attachment_object_outbox;
DROP TRIGGER IF EXISTS trg_audit_account_flow_monthly_summaries ON account_flow_monthly_summaries;

-- 幂等指令表：命令去重记录，与对应请求级审计行重复
DROP TRIGGER IF EXISTS trg_audit_production_daily_report_commands ON production_daily_report_commands;
DROP TRIGGER IF EXISTS trg_audit_production_fqc_release_commands ON production_fqc_release_commands;
DROP TRIGGER IF EXISTS trg_audit_warehouse_arrival_registration_commands ON warehouse_arrival_registration_commands;
DROP TRIGGER IF EXISTS trg_audit_production_material_analysis_commands ON production_material_analysis_commands;
