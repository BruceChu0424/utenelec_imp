-- V549 清空业务数据的附件保护集扩到主档 owner（GOODS）。
--
-- 背景（2026-09-10 审计 H1-3）：fn_business_attachment_reset_blockers() 的保护集自 V537/V539
-- 起只按「人事」硬编码（EMPLOYEE / EMPLOYEE_CONTRACT），而货品主档附件（owner_type = GOODS：
-- 产品图片/图纸/规格书）所属的 goods 表在 business_data_reset() 中是 PRESERVE。清空流程
-- 自 2026-09-09 起会在清库前自动把「阻塞项」标删并物理删除——若不扩保护集，货品主档的
-- 图片/图纸会随测试清空被物理删除，与主档保留语义冲突。
--
-- 本迁移只 CREATE OR REPLACE 该函数，函数体与 V539 逐字一致，仅把两处保护集改为
-- ('EMPLOYEE','EMPLOYEE_CONTRACT','GOODS')；不新增表、不改 CLEAR/PRESERVE 分类、不改
-- business_data_reset()。Java 侧 BusinessAttachmentResetPreparation.PROTECTED_OWNER_TYPES
-- 持同一集合（入队/读取/计数四处共用），两侧必须同步维护。可重复执行。
CREATE OR REPLACE FUNCTION fn_business_attachment_reset_blockers()
RETURNS TABLE(entity_type TEXT, entity_id UUID, owner_type TEXT, owner_id UUID, reason TEXT)
LANGUAGE sql STABLE AS $$
WITH business_attachments AS MATERIALIZED (
    SELECT * FROM attachments WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT','GOODS')
), business_sessions AS MATERIALIZED (
    SELECT * FROM attachment_upload_sessions WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT','GOODS')
), safe_attachments AS MATERIALIZED (
    SELECT attachment.id FROM business_attachments attachment
    WHERE attachment.lifecycle_state='DELETED'
      AND attachment.storage_provider IN ('internal','local','oss')
      AND EXISTS (
          SELECT 1 FROM attachment_object_outbox operation
          WHERE operation.attachment_id=attachment.id AND operation.operation='DELETE_FINAL'
            AND operation.storage_provider=attachment.storage_provider AND operation.storage_key=attachment.storage_key
            AND operation.storage_version IS NOT DISTINCT FROM attachment.storage_version
            AND operation.status='SUCCEEDED' AND operation.completed_at IS NOT NULL)
)
SELECT 'ATTACHMENT', attachment.id, attachment.owner_type::text, attachment.owner_id,
       CASE WHEN attachment.storage_provider='legacy_unknown' THEN '原件存储位置尚未确认，请先对账'
            WHEN attachment.lifecycle_state='DELETED' THEN '缺少原件已删除的完成记录'
            WHEN attachment.lifecycle_state='CLEAN' THEN '文件仍在使用，需先确认删除'
            ELSE '原件删除尚未完成' END
FROM business_attachments attachment WHERE NOT EXISTS(SELECT 1 FROM safe_attachments safe WHERE safe.id=attachment.id)
UNION ALL
SELECT 'UPLOAD_SESSION', session.id, session.owner_type::text, session.owner_id,
       CASE WHEN session.expires_at>now() THEN '上传凭证仍有效，请等待到期后刷新'
            WHEN session.status IN ('PENDING','SCANNING') THEN '上传会话尚未结束'
            ELSE '临时文件或原件尚缺少删除完成证明，请先核对文件' END
FROM business_sessions session
WHERE session.storage_provider NOT IN ('internal','local','oss')
   OR session.status NOT IN ('PROMOTED','REJECTED','EXPIRED') OR session.expires_at>now()
   OR NOT EXISTS (
       SELECT 1 FROM attachment_object_outbox operation
       WHERE operation.upload_session_id=session.id AND operation.operation='DELETE_STAGING'
         AND operation.storage_provider=session.storage_provider AND operation.storage_key=session.storage_key
         AND (session.staging_version IS NULL OR operation.storage_version IS NOT DISTINCT FROM session.staging_version)
         AND operation.status='SUCCEEDED' AND operation.completed_at>=session.expires_at)
   OR (session.status='PROMOTED' AND NOT EXISTS (
       SELECT 1 FROM business_attachments attachment JOIN safe_attachments safe ON safe.id=attachment.id
       WHERE attachment.storage_provider=session.storage_provider AND attachment.storage_key=session.storage_key
         AND attachment.owner_type=session.owner_type AND attachment.owner_id=session.owner_id
         AND attachment.storage_version IS NOT DISTINCT FROM session.final_version))
   OR (session.status IN ('REJECTED','EXPIRED') AND NOT EXISTS (
       SELECT 1 FROM attachment_object_outbox operation
       WHERE operation.upload_session_id=session.id AND operation.operation='DELETE_FINAL'
         AND operation.storage_provider=session.storage_provider AND operation.storage_key=session.storage_key
         AND operation.storage_version IS NOT DISTINCT FROM session.final_version
         AND operation.status='SUCCEEDED' AND operation.completed_at>=session.expires_at))
UNION ALL
SELECT 'DELETE_OPERATION', operation.id,
       coalesce(attachment.owner_type,session.owner_type,'UNKNOWN')::text,
       coalesce(attachment.owner_id,session.owner_id), '文件删除队列仍在处理或失败，请等待或核对'
FROM attachment_object_outbox operation
LEFT JOIN business_attachments attachment ON attachment.id=operation.attachment_id
LEFT JOIN business_sessions session ON session.id=operation.upload_session_id
WHERE (operation.status<>'SUCCEEDED' OR operation.completed_at IS NULL)
  AND (attachment.id IS NOT NULL OR session.id IS NOT NULL
       OR (operation.attachment_id IS NULL AND operation.upload_session_id IS NULL));
$$;
