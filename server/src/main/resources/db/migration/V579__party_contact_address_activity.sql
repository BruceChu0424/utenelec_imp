-- V579 基础资料联系方式 / 地址 / 跟进记录子表（客户 + 供应商共用）。
--
-- 背景（2026-09-14 用户需求）：客户/供应商主档的联系方式与地址全是平铺单值列
-- （mobile/phone/phone2/fax/email/website/address/ship_address），无法登记多个联系人
-- 电话或多个地址；也没有客户行为记录与信誉分。本迁移：
--   1. party_contact_methods：多联系方式（手机/电话/传真/邮箱/网址/其它），
--      从两表既有平铺列回填，老数据一个不丢；
--   2. party_addresses：多地址（收货/开票/其它），同样回填；
--   3. party_activity_records：跟进/投诉/违约扣分/奖励等行为记录；
--   4. clients.credit_score：信誉分（NULL=从未评估；首条带分数记录落地时按 100±delta 初始化）。
-- 平铺列保留不删：单据、导出与老接口继续读它；服务端在联系方式变化时把
-- 「每类第一条」同步回平铺列，保证两套口径一致。

CREATE TABLE party_contact_methods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    party_type VARCHAR(16) NOT NULL CHECK(party_type IN ('CLIENT','SUPPLIER')),
    party_id UUID NOT NULL,
    kind VARCHAR(16) NOT NULL CHECK(kind IN ('MOBILE','PHONE','FAX','EMAIL','WEBSITE','OTHER')),
    value TEXT NOT NULL CHECK(length(btrim(value)) BETWEEN 1 AND 200),
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    remark TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    updated_at TIMESTAMPTZ
);
CREATE INDEX idx_party_contact_methods_party ON party_contact_methods(party_type, party_id, kind);

CREATE TABLE party_addresses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    party_type VARCHAR(16) NOT NULL CHECK(party_type IN ('CLIENT','SUPPLIER')),
    party_id UUID NOT NULL,
    kind VARCHAR(16) NOT NULL DEFAULT 'SHIPPING' CHECK(kind IN ('SHIPPING','BILLING','OTHER')),
    address TEXT NOT NULL CHECK(length(btrim(address)) BETWEEN 2 AND 500),
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    remark TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    updated_at TIMESTAMPTZ
);
CREATE INDEX idx_party_addresses_party ON party_addresses(party_type, party_id, kind);

CREATE TABLE party_activity_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    party_type VARCHAR(16) NOT NULL CHECK(party_type IN ('CLIENT','SUPPLIER')),
    party_id UUID NOT NULL,
    kind VARCHAR(16) NOT NULL CHECK(kind IN ('FOLLOW_UP','COMPLAINT','PENALTY','REWARD','OTHER')),
    content TEXT NOT NULL CHECK(length(btrim(content)) BETWEEN 2 AND 2000),
    score_delta INT NOT NULL DEFAULT 0 CHECK(score_delta BETWEEN -100 AND 100),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    updated_at TIMESTAMPTZ
);
CREATE INDEX idx_party_activity_records_party ON party_activity_records(party_type, party_id, created_at DESC);

ALTER TABLE clients ADD COLUMN credit_score INT CHECK(credit_score BETWEEN 0 AND 200);

-- 审计触发器（对齐全库口径：一表一 trg_audit_*，ALWAYS）。
-- 逐条字面写，不用 DO + format 动态生成：AuditTriggerCoverageMigrationContractTest
-- 要求「新表必须自带**可评审**的行级审计触发器」，判定方式就是在迁移正文里找
-- `create trigger trg_audit_<表>` / `after insert or update or delete on <表>` /
-- `for each row execute function fn_audit()` 三段字面量。动态循环等于把审计口径
-- 藏进运行期字符串，评审看不见，契约也认不出。
CREATE TRIGGER trg_audit_party_contact_methods
    AFTER INSERT OR UPDATE OR DELETE ON party_contact_methods
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE party_contact_methods
    ENABLE ALWAYS TRIGGER trg_audit_party_contact_methods;

CREATE TRIGGER trg_audit_party_addresses
    AFTER INSERT OR UPDATE OR DELETE ON party_addresses
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE party_addresses
    ENABLE ALWAYS TRIGGER trg_audit_party_addresses;

CREATE TRIGGER trg_audit_party_activity_records
    AFTER INSERT OR UPDATE OR DELETE ON party_activity_records
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE party_activity_records
    ENABLE ALWAYS TRIGGER trg_audit_party_activity_records;

-- ===== 老数据回填：每条非空平铺列 → 一条联系方式/地址 =====
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'MOBILE', btrim(mobile), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(mobile,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'PHONE', btrim(phone), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(phone,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'PHONE', btrim(phone2), FALSE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(phone2,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'FAX', btrim(fax), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(fax,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'EMAIL', btrim(email), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(email,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'CLIENT', id, 'WEBSITE', btrim(website), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(website,'')) <> '';

INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'MOBILE', btrim(mobile), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(mobile,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'PHONE', btrim(phone), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(phone,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'PHONE', btrim(phone2), FALSE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(phone2,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'FAX', btrim(fax), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(fax,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'EMAIL', btrim(email), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(email,'')) <> '';
INSERT INTO party_contact_methods (party_type, party_id, kind, value, is_primary, created_at)
SELECT 'SUPPLIER', id, 'WEBSITE', btrim(website), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(website,'')) <> '';

-- 地址：address 视作开票/注册地址（BILLING），ship_address 视作收货地址（SHIPPING）。
INSERT INTO party_addresses (party_type, party_id, kind, address, is_default, created_at)
SELECT 'CLIENT', id, 'BILLING', btrim(address), FALSE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(address,'')) <> '';
INSERT INTO party_addresses (party_type, party_id, kind, address, is_default, created_at)
SELECT 'CLIENT', id, 'SHIPPING', btrim(ship_address), TRUE, now() FROM clients
WHERE NOT is_deleted AND btrim(COALESCE(ship_address,'')) <> '';
INSERT INTO party_addresses (party_type, party_id, kind, address, is_default, created_at)
SELECT 'SUPPLIER', id, 'BILLING', btrim(address), FALSE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(address,'')) <> '';
INSERT INTO party_addresses (party_type, party_id, kind, address, is_default, created_at)
SELECT 'SUPPLIER', id, 'SHIPPING', btrim(ship_address), TRUE, now() FROM suppliers
WHERE NOT is_deleted AND btrim(COALESCE(ship_address,'')) <> '';

COMMENT ON TABLE party_contact_methods IS '客户/供应商多联系方式（V579）；每类第一条同步回主档平铺列';
COMMENT ON TABLE party_addresses IS '客户/供应商多地址（V579）';
COMMENT ON TABLE party_activity_records IS '客户/供应商跟进与行为记录（V579）；带分数变动时同步 clients.credit_score';
COMMENT ON COLUMN clients.credit_score IS '客户信誉分（V579）：NULL=从未评估，首条评分记录按 100±delta 初始化';


-- ===== 运行时清空函数补丁（V474 模式；V464 已应用字节不可改） =====
-- 三张子表注册为 PRESERVE 随主档保留；锚点缺失即失败关闭。
DO $reset_patch$
DECLARE
    definition TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure)
    INTO definition;
    patched := replace(
        definition,
        '(''clients'', ''PRESERVE''),',
        '(''clients'', ''PRESERVE''),' || E'
    ' ||
        '(''party_activity_records'', ''PRESERVE''),' || E'
    ' ||
        '(''party_addresses'', ''PRESERVE''),' || E'
    ' ||
        '(''party_contact_methods'', ''PRESERVE''),');
    IF patched IS NOT DISTINCT FROM definition THEN
        RAISE EXCEPTION 'V579 cannot extend business_data_reset policy safely'
            USING ERRCODE='23514';
    END IF;
    EXECUTE patched;
END;
$reset_patch$;
