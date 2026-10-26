-- Client package publication is separate from permission administration and server operations.
-- Existing ordinary users remain closed until a super administrator grants this capability individually.
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,
                        high_risk,baseline,baseline_pinned,explicit_grant_required)
VALUES ('client_release:publish','发布客户端版本','系统管理','客户端更新',250,'EXECUTE',
        '查看客户端发布记录、准备及上传更新包、发布和撤回客户端版本；仅超级管理员逐人授权，不可部门授权或转授，不含服务器更新及权限管理',
        ARRAY['INDIVIDUAL_ONLY']::text[],TRUE,FALSE,FALSE,TRUE);

INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES ('cfc58d9b-6174-4b27-b45e-f3b98c98dcdd','admin.client-releases','发布客户端版本',906,TRUE);

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key='admin.client-releases' AND permission.code='client_release:publish';
