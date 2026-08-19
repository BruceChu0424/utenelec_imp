-- V300：客户收货地址簿（出货联系信息学习能力）+ 销售订单财务驳回事实列。
--
-- 背景（2026-08-18 销售开单体验整改）：
--   ① 新建销售订货单不再填写联系电话/收货地址——收货联系信息属于发货环节，
--     由出货单承载；订货单合同信息段保留 合同号/签约地点/订金。
--   ② 出货开单选择客户（或从订货单引入回填客户）后，自动带出该客户最近使用的
--     收货地址+联系电话；客户主档没有、用户手填过一次即被"记住"（本表 upsert 学习），
--     下次默认带出且可改，改过的内容保存时再次学习更新。
--   ③ 一个客户可有多个收货地址：地址弹窗可查看/选择/新增；删除地址是敏感操作，
--     需要独立权限点 client_address:delete（默认授予综合营销部与 GM，可权限设置调整）。
--   ④ 销售订单财务确认补充「驳回」决策：驳回不改动订单状态与库存预留，只记录
--     驳回事实+原因并通知归属销售；订单仍留在待确认池（标记已驳回），财务可后续确认
--     （确认自动清除驳回标记）。镜像大公司审批中心"通过/驳回"双决策模型。
--
-- 设计：
--   client_ship_addresses 以客户维度记录收货地址簿：地址去重（客户内规范化地址唯一）、
--   使用次数/最近使用时间驱动默认排序，软删保留审计事实。
--   sales_orders 增加 finance_rejected 族列，与 finance_confirmed 族列对称。

-- ===== ① 客户收货地址簿 =====
CREATE TABLE client_ship_addresses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    address         TEXT NOT NULL,
    link_phone      VARCHAR(64),
    usage_count     INTEGER NOT NULL DEFAULT 1,
    last_used_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID REFERENCES employees(id) ON DELETE RESTRICT,
    updated_by      UUID REFERENCES employees(id) ON DELETE RESTRICT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at      TIMESTAMPTZ,
    CONSTRAINT client_ship_addresses_address_chk
        CHECK (address = btrim(address) AND length(address) BETWEEN 2 AND 500),
    CONSTRAINT client_ship_addresses_phone_chk
        CHECK (link_phone IS NULL OR length(btrim(link_phone)) BETWEEN 3 AND 64),
    CONSTRAINT client_ship_addresses_usage_chk CHECK (usage_count >= 0)
);

COMMENT ON TABLE client_ship_addresses IS
    '客户收货地址簿（V300）：出货开单按客户学习收货地址+联系电话，最近使用优先带出；删除需 client_address:delete';
COMMENT ON COLUMN client_ship_addresses.usage_count IS
    '被出货单据使用次数（学习热度；默认排序依据之一）';
COMMENT ON COLUMN client_ship_addresses.last_used_at IS
    '最近一次被出货单保存引用的时间（默认带出排序主键）';

-- 同一客户内规范化地址唯一（软删行不占用唯一位，删除后可重建同地址）。
CREATE UNIQUE INDEX uq_client_ship_addresses_addr
    ON client_ship_addresses(client_id, md5(lower(btrim(address))))
    WHERE is_deleted = FALSE;
CREATE INDEX idx_client_ship_addresses_client
    ON client_ship_addresses(client_id, last_used_at DESC)
    WHERE is_deleted = FALSE;

CREATE TRIGGER trg_set_updated_at_client_ship_addresses
    BEFORE UPDATE ON client_ship_addresses
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ===== ② 销售订单财务驳回事实列 =====
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_rejected BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_rejected_reason TEXT;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_rejected_by UUID REFERENCES employees(id);
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_rejected_at TIMESTAMPTZ;

COMMENT ON COLUMN sales_orders.finance_rejected IS
    '财务驳回（V300）：财务确认人驳回订单待修正；不改订单状态/预留，确认后自动清除';
COMMENT ON COLUMN sales_orders.finance_rejected_reason IS
    '财务驳回原因（必填，写入通知与审计）';

-- ===== ③ 地址删除权限点（默认 综合营销部 + GM；超管恒有）=====
INSERT INTO permissions(code, name, module, category, sort_order) VALUES
    ('client_address:delete', '删除客户收货地址', '基础资料', '客户资料', 598)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'client_address:delete'
WHERE d.code IN ('DEPT_SALES', 'GM') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ===== ④ 审计覆盖刷新（新表 client_ship_addresses 纳入全 public 审计强校验）=====
DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'category_master_code_sequences', 'business_document_sequences',
              'production_product_no_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT count(*),
               count(*) FILTER (WHERE
                   audit_trigger.tgenabled IN ('O', 'A')
                   AND (audit_trigger.tgtype::INTEGER & 1) = 1
                   AND (audit_trigger.tgtype::INTEGER & 2) = 0
                   AND (audit_trigger.tgtype::INTEGER & 4) = 4
                   AND (audit_trigger.tgtype::INTEGER & 8) = 8
                   AND (audit_trigger.tgtype::INTEGER & 16) = 16
                   AND function_schema.nspname = 'public'
                   AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
        INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;
        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit* triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()', table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'category_master_code_sequences', 'business_document_sequences',
          'production_product_no_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*) FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
