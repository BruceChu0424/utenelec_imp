-- 2026-11-09 附件「最近使用时间」: 冷热分层的访问热度落在附件自己的列上(ADR-105: 审计日志只留证,
-- 业务不读审计日志)。下载授权(download-grant)、本地原件下载与在线预览通过权限校验并写好审计后,
-- 以独立短事务按天节流推进本列; 冷存调度只读本列: 近 90 天用过的附件不论多老都留在热盘,
-- 已冷存的重新用起来搬回热盘。
-- 列名取 fn_audit 运维列清单里的 last_used_at(与 updated_at/last_login_at 同类): 只推进本列的
-- UPDATE 不产生整行审计事件, attachments 仍按 V670 FULL 整行审计, 其余列改动照常留痕。
-- 不加索引: 调度每晚只扫一次, 本列不进任何索引, 推进写仍可走 HOT 更新, 不放大附件表索引写入。
ALTER TABLE public.attachments ADD COLUMN last_used_at timestamptz;
COMMENT ON COLUMN public.attachments.last_used_at IS
    '最近一次下载/下载授权/在线预览的时间(按天节流推进); NULL=上线前 90 天内及之后未被使用, 只按年龄分层';

-- 上线当天回填一次: 审计日志近 90 天三类访问事件(本地原件下载、下载授权、在线预览)的最晚时间,
-- 让首晚的热度判定与原按审计日志计算的窗口一致。target_id 是 text, 只把合法 UUID 文本转成附件主键;
-- 已删除历史(RETAINED_HISTORY)整行不可变(trg_attachment_retained_identity_guard), 不回填;
-- 只前进不后退, 重复执行结果不变。按月分区的 audit_log 只读最近 90 天所在分区。
UPDATE public.attachments a
   SET last_used_at = recent.last_used_at
  FROM (SELECT CASE WHEN l.target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    THEN l.target_id::uuid END AS attachment_id,
               max(l.created_at) AS last_used_at
          FROM public.audit_log l
         WHERE l.target_type = 'attachments'
           AND l.action IN ('attachment_download_raw', 'attachment_download_grant', 'attachment_preview')
           AND l.created_at >= now() - interval '90 days'
         GROUP BY 1) recent
 WHERE recent.attachment_id IS NOT NULL
   AND a.id = recent.attachment_id
   AND a.lifecycle_state <> 'RETAINED_HISTORY'
   AND (a.last_used_at IS NULL OR a.last_used_at < recent.last_used_at);
