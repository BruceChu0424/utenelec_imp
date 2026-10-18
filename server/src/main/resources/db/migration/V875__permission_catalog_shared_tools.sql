-- V875：共享工具归类与纯展示元数据不撤销既有委派。
-- permissions 是目录唯一事实源；不改 code/id、授权策略、基础包或任何授权行。
-- V135 原来对任意目录 UPDATE 推进授权纪元，改分类也会令 V322 的有效委派失效。
-- 仅排除明确的展示/编辑时间字段，未来新增的授权字段默认仍推进纪元，避免漏失效。
CREATE OR REPLACE FUNCTION fn_bump_permission_catalog_update_epoch()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM old_permission_rows old_row
        FULL JOIN new_permission_rows new_row ON new_row.id = old_row.id
        WHERE (to_jsonb(old_row) - ARRAY['module', 'category', 'sort_order', 'updated_at', 'updated_by'])
              IS DISTINCT FROM
              (to_jsonb(new_row) - ARRAY['module', 'category', 'sort_order', 'updated_at', 'updated_by'])
    ) THEN
        UPDATE authorization_state
        SET epoch = epoch + 1, updated_at = CURRENT_TIMESTAMP
        WHERE singleton_id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER trg_permissions_authorization_epoch ON permissions;
CREATE TRIGGER trg_permissions_authorization_epoch
AFTER INSERT OR DELETE OR TRUNCATE ON permissions
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_permissions_update_authorization_epoch
AFTER UPDATE ON permissions
REFERENCING OLD TABLE AS old_permission_rows NEW TABLE AS new_permission_rows
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_permission_catalog_update_epoch();

-- 对话/文件识别与个人 AI 偏好是跨业务共享工具。
-- 服务商、模型、密钥、计费和用量管理仍使用系统管理的 authorization:manage + 超管。
UPDATE permissions
SET module = '通用', category = 'AI 助手'
WHERE code = 'ai:use';

-- V745 的报价导出曾单列「销售报价单」，应与报价其余动作同组。
UPDATE permissions
SET category = '销售报价'
WHERE code = 'sales_quote:export';

DO $$
BEGIN
    IF (SELECT count(*) FROM permissions
        WHERE code = 'ai:use' AND module = '通用' AND category = 'AI 助手') <> 1 THEN
        RAISE EXCEPTION 'V875 AI usage must be classified under shared tools';
    END IF;
    IF (SELECT count(*) FROM permissions
        WHERE code = 'sales_quote:export' AND module = '销售管理' AND category = '销售报价') <> 1 THEN
        RAISE EXCEPTION 'V875 quotation export must share the quotation category';
    END IF;
END;
$$;
