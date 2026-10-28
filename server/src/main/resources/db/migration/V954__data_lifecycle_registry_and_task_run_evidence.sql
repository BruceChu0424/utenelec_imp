-- B3-W3: 数据生命周期策略清册 + 持久任务运行证据。
--
-- 现状：唯一的分类清册(318 表 CLEAR/PRESERVE)随 V915/V919 测试重置退役；各域
-- 保留策略散落在迁移注释与 ADR 中，管理员无处可见「保存了什么、按什么规则」；
-- 36 个后台任务只有内存运行注册表，重启即空，仅审计归档有持久证据。
--
-- 本迁移：
--   1) data_lifecycle_policies：全平台数据生命周期策略清册(种子按当前真实行为登记,
--      不是目标态)；策略变更走前向迁移, 不在运行时接口修改；
--   2) scheduled_task_runs：治理类低频任务的完成回执持久化(高频轮询仍只留内存观测)，
--      服务器状态页重启后仍能显示最近执行证据。

CREATE TABLE data_lifecycle_policies (
    policy_key          VARCHAR(80) PRIMARY KEY,
    domain              VARCHAR(40) NOT NULL,
    subject             TEXT NOT NULL,
    purpose             TEXT NOT NULL,
    retention_contract  VARCHAR(40) NOT NULL,
    term_note           TEXT NOT NULL,
    tier_path           TEXT,
    authoritative_note  TEXT NOT NULL,
    housekeeping_task   VARCHAR(120),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT data_lifecycle_contract_chk CHECK (retention_contract IN (
        'PERMANENT_RETAIN', 'PERMANENT_RETAIN_TIERED', 'SOFT_ARCHIVE',
        'EPHEMERAL_PERSONAL_STATE', 'REGENERABLE_CACHE', 'CREDENTIAL_LIFECYCLE',
        'TRANSIENT_IO', 'REBUILDABLE_PROJECTION'))
);

COMMENT ON TABLE data_lifecycle_policies IS
    '数据生命周期策略清册：按当前真实行为登记每类数据的用途、留存合同、期限口径、分层路径、'
    '权威真源与维护任务；只读暴露给管理端，策略变更走前向迁移';

INSERT INTO data_lifecycle_policies
    (policy_key, domain, subject, purpose, retention_contract, term_note,
     tier_path, authoritative_note, housekeeping_task)
VALUES
 ('audit_online','审计','audit_log 在线月分区',
  '员工与访客操作、数据变更、安全事件的在线审计证据',
  'PERMANENT_RETAIN','在线留存 audit_hot_retention_months 个月(默认 6), 到期整月转冷归档分区',
  'audit_log_archive','审计原始事实; 归档搬移同库同事务','AuditRetentionScheduler.runScheduled'),
 ('audit_archive','审计','audit_log_archive 冷归档月分区',
  '超在线保留期的审计证据冷层',
  'PERMANENT_RETAIN','只搬不删(PERMANENT_RETAIN/PRESERVE_UNCLASSIFIED, V770/V786), 无销毁期限',
  NULL,'与在线表逐列同形, 统一读取经 v_audit_log_all','AuditRetentionScheduler.runScheduled'),
 ('business_outbox','通知','business_outbox 事件热表',
  '业务事件的可靠投递与调用方幂等防重',
  'PERMANENT_RETAIN_TIERED','防重身份(dedupe_key/event_type/aggregate)永久留热表; 送达满 90 天载荷无损分层',
  'business_outbox_payload_history','防重等价比较经 v_business_outbox_full 跨层取完整载荷',
  'BusinessOutboxPayloadTieringScheduler.tierDeliveredPayloads'),
 ('business_outbox_payload_history','通知','business_outbox_payload_history',
  '已送达事件的完整载荷原文(无损分层层)',
  'PERMANENT_RETAIN','随热行分层写入, 不再做年龄处理; status=0/2 永不迁入',
  NULL,'与热行同事务写入, md5 指纹随行','BusinessOutboxPayloadTieringScheduler.tierDeliveredPayloads'),
 ('notices','通知','站内通知(notices)',
  '员工工作台的通知事实',
  'PERMANENT_RETAIN','处理只更新状态, 不按年龄删除',
  NULL,'投递与已读事实保留','BusinessOutboxScheduler.drain'),
 ('ai_jobs','AI','ai_jobs / ai_call_logs',
  'AI 识别任务与调用记录',
  'SOFT_ARCHIVE','结果 48 小时清空; 任务 7 天、调用 180 天转 archived_at 软归档, 原文与行保留(V773/V778)',
  NULL,'识别输入原件独立保留于 ai_input_originals','AiJobHousekeeping.purge'),
 ('ai_input_originals','AI','ai_input_originals 识别原件',
  'AI 识别的原始输入文件',
  'PERMANENT_RETAIN','未采用来源只登记归档状态, 原文件与关联保留',
  NULL,'外置存储引用 + 哈希校验','AiInputOriginalCleanup.purge'),
 ('ai_chat_action_proposals','AI','ai_chat_action_proposals 聊天确认卡',
  'AI 助手待确认操作卡(用户个人暂态工作区)',
  'EPHEMERAL_PERSONAL_STATE','签发满保留天数(默认 7 天)后硬删; 可由对话重新生成, 不构成业务证据',
  NULL,'业务事实以确认后落库的单据为准','AiJobHousekeeping.purge'),
 ('ai_chat_operation_memory','AI','ai_chat_operation_memory 操作记忆',
  'AI 助手按人记忆的近期操作上下文',
  'EPHEMERAL_PERSONAL_STATE','90 天未使用后硬删; 个人暂态, 不构成业务证据',
  NULL,'业务事实以单据为准','AiJobHousekeeping.purge'),
 ('sales_learning_receipts','学习','sales_document_learning_receipts',
  '销售单据学习的原请求回执与证据',
  'SOFT_ARCHIVE','超过重试期转 archived_at, 学习结果与处理记录保留; 原载荷禁清空(V778 触发器)',
  NULL,'模板学习采用链的事实来源','SalesLearningEvidenceCleanupScheduler.purgeExpiredEvidence'),
 ('quote_template_candidates','学习','sales_quote_template_candidates',
  '客户报价模板候选与已采用版本',
  'SOFT_ARCHIVE','过期未采用转 archived_at; 已采用模板版本永久保留',
  'sales_quote_template_candidate_history','候选历史与私有存储引用已入备份与孤儿核对','SalesQuoteTemplateCleanupScheduler.purgeExpired'),
 ('attachments','附件','attachments 登记与正式原件',
  '业务附件与原件字节',
  'PERMANENT_RETAIN','删除仅标记 RETAINED_HISTORY, 原件字节/哈希/权限/历史入口保留(V777); 暂存件例外',
  'attachment history','原件哈希四重校验后才能读取','AttachmentObjectOutboxScheduler.drain'),
 ('upload_staging_scratch','附件','上传暂存与工作目录',
  '未确认上传的临时字节与可再生工作文件',
  'TRANSIENT_IO','24 小时清理; 未确认内容不属于业务证据',
  NULL,'确认后的正式原件走 attachments 合同','InternalStorageScratchScheduler.cleanup'),
 ('attachment_previews','附件','预览缓存',
  '原件的衍生预览(可再生)',
  'REGENERABLE_CACHE','按容量与原件哈希失效重建, 不参与备份对账',
  NULL,'原件字节是唯一权威',''),
 ('report_export_files','报表','报表导出产物文件',
  '持久导出任务的成品文件',
  'REGENERABLE_CACHE','下载期满后删除文件, 任务行/审计/下载授权记录保留(V938)',
  NULL,'原业务数据不受导出影响','ReportExportWorker.poll'),
 ('refresh_tokens','安全','refresh_tokens / visitor_refresh_tokens',
  '登录会话刷新凭据',
  'CREDENTIAL_LIFECYCLE','到期/撤销按凭据生命周期处理, 不为追溯延长寿命',
  NULL,'安全事件留脱敏审计证据',''),
 ('visitor_sms_codes','安全','访客短信验证码',
  '访客登录的一次性凭据',
  'CREDENTIAL_LIFECYCLE','短时有效; 投递与核销结果证据保留',
  NULL,'供应商明确拒绝才释放发送额度',''),
 ('business_record_history','治理','business_record_history / identities',
  '业务单据删除快照与永久身份绑定',
  'PERMANENT_RETAIN','删除原文与身份防复用永久保留(V775)',
  NULL,'跨制单重用身份被拒绝',''),
 ('lifecycle_versions','治理','生命周期版本与交付历史(V778 族)',
  '模板版本、通知祝福、AI 提供方等版本历史',
  'PERMANENT_RETAIN','永久保留, 不按年龄销毁',
  NULL,'版本原文与操作记录完整',''),
 ('stock_flow_ledger','库存','stock_movements / stock_balances',
  '库存流水(append-only)与当前余额',
  'PERMANENT_RETAIN','同事务维护, 不做年龄分层; 报表汇总可重建',
  NULL,'库存数量/重量的唯一权威事实',''),
 ('stock_monthly_summaries','库存','stock_monthly_summaries',
  '库存月度汇总投影(B2)',
  'REBUILDABLE_PROJECTION','触发器同事务增量 + 排他锁重建; 日常对账与分块核对只告警不修复',
  NULL,'原始流水权威(V949)','StockMonthlyVerificationScheduler.verifyChunk'),
 ('party_monthly_summaries','财务','party_monthly_summaries / party_month_dirty',
  '客户/供应商往来月度汇总投影(B2)',
  'REBUILDABLE_PROJECTION','脏期间整格重算, 读取前自愈; 无水位, 迟到/乱序/红冲天然正确',
  NULL,'往来台账事件权威(V950)','PartyMonthlySummaryScheduler.drain'),
 ('report_materialized_views','报表','销售/采购/生产/委外物化视图',
  '报表月度汇总的过渡投影',
  'REBUILDABLE_PROJECTION','每 5 分钟并发刷新; 无读者的两张已退出刷新(V951)',
  NULL,'原始单据权威; 按成本逐张改造','MaterializedViewRefreshScheduler.refreshAll'),
 ('reconciliation_findings','附件','attachment_reconciliation_findings',
  '存储对账差异证据与处置',
  'PERMANENT_RETAIN','观察/审批/处置状态保留, 物理删除须权限与依据',
  NULL,'差异不自动消除','AttachmentReconciliationService.scheduledReconcile'),
 ('client_drafts','草稿','本机/正式草稿',
  '未提交编辑内容与已结束草稿历史',
  'PERMANENT_RETAIN','完整内容与结束状态保留; 身份与权限隔离',
  NULL,'按操作 ID 定位, 每版原文保留',''),
 ('scheduled_task_runs','治理','scheduled_task_runs',
  '治理类后台任务的完成回执(本迁移新建)',
  'PERMANENT_RETAIN','低频治理任务逐次留痕; 高频轮询仅内存观测',
  NULL,'任务运行证据, 不含业务数据',''),
 ('data_lifecycle_policies','治理','本清册',
  '数据生命周期策略登记',
  'PERMANENT_RETAIN','策略变更走前向迁移, 运行时只读',
  NULL,'本表即权威','');

-- 治理类任务完成回执：只记完成事实(开始/结束/耗时/结果/错误类型), 不记业务数据。
CREATE TABLE scheduled_task_runs (
    id          BIGSERIAL PRIMARY KEY,
    task_key    VARCHAR(120) NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL,
    duration_ms BIGINT NOT NULL DEFAULT 0,
    outcome     VARCHAR(10) NOT NULL CONSTRAINT scheduled_task_runs_outcome_chk
                CHECK (outcome IN ('SUCCESS', 'FAILURE')),
    error_type  VARCHAR(200),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_scheduled_task_runs_task_time
    ON scheduled_task_runs(task_key, started_at DESC);

COMMENT ON TABLE scheduled_task_runs IS
    '后台治理任务完成回执：由内存注册表对低频治理任务写穿, 重启后状态页仍能显示最近执行证据;'
    '高频轮询任务不写本表';

SELECT fn_audit_track_table('data_lifecycle_policies','FULL','system',false);
SELECT fn_audit_track_table('scheduled_task_runs','NONE','system',true);
