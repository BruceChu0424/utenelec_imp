-- Manual server update and controlled cleanup capabilities; super-admin grants only.
-- No existing grants/settings/source credentials are changed.
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,high_risk,baseline)
VALUES
 ('server:update','检查及更新服务器','系统管理','服务器运维',248,'EXECUTE',
  '手动检查受信发布源，立即或预约更新及取消本人预约；仅超级管理员逐人授权，不可委派，不含发布源或密钥配置',
  ARRAY['INDIVIDUAL_ONLY']::text[],TRUE,FALSE),
 ('server:cleanup','受控清理服务器资源','系统管理','服务器运维',249,'DELETE',
  '预览并清理助手列出的可清理资源；只接受资源标识，保留运行版本、回滚及备份保护，不含发布源或密钥配置',
  ARRAY['INDIVIDUAL_ONLY']::text[],TRUE,FALSE);
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES ('beed11ef-3158-4735-a05c-bca84c63bb74','admin.server-operations','服务器运维',905,TRUE);
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key='admin.server-operations' AND permission.code IN ('server:update','server:cleanup');
