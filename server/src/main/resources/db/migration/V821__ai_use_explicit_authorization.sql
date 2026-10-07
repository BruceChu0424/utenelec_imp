-- V821: AI 使用权回归按需授权，并在账号与权限管理提供独立设置抽屉。
-- 最新要求取代 V813 的全员自动开放：只移出基础包，不删除既有部门/个人授权或收回。
-- AI 使用不授予业务操作、权限管理、服务商模型或密钥管理权限。
UPDATE permissions
SET baseline = FALSE,
    description = '有授权才可使用 AI 助手（对话与文件识别）；办理业务还需对应业务权限，模型与密钥管理另按系统管理权限控制'
WHERE code = 'ai:use';

INSERT INTO permission_surfaces(id, surface_key, name, sort_order, enabled)
VALUES ('82100000-0000-4000-8000-000000000001', 'system.ai-assistant', 'AI 使用', 200, TRUE);

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code = 'ai:use'
WHERE surface.surface_key = 'system.ai-assistant';

DO $$
BEGIN
    IF (SELECT count(*) FROM permissions WHERE code = 'ai:use' AND NOT baseline) <> 1 THEN
        RAISE EXCEPTION 'AI 使用权限必须按需授权，不再自动加入全员基础包';
    END IF;
    IF (SELECT count(*) FROM permission_surface_permissions link
        JOIN permission_surfaces surface ON surface.id = link.surface_id
        WHERE surface.surface_key = 'system.ai-assistant') <> 1 THEN
        RAISE EXCEPTION 'AI 使用权限面必须仅包含 ai:use';
    END IF;
END;
$$;
