-- B3-W4: 归档资格登记 + 采购订单完整对象归档试点（低风险，只复制校验、不搬移不删除）。
--
-- 现状：业务表无 archived_at、无归档资格判定；「已结清满 24 个月」在 07 方案中只是
-- 候选门槛, 且要求最终结清取履约/收付款核销/质量处置的最晚者、缺可信结清日的旧单
-- 只进待核验清册。
--
-- 本迁移（试点族 = PURCHASE_ORDER, 扇入最小、终态最明确的业务对象家族）：
--   1) business_archive_eligibility：资格评估登记（每次扫描整行重算 upsert）。
--      阻碍原因逐条留痕：未结案/未审、未结质量案件、草稿收货或退回、未结清台账、
--      结清日期不可得（不拿创建日补）、结清未满候选期。
--   2) business_archive_packages：完整对象族的校验快照包（原单+明细+审批+收货+
--      退回+台账+质量案件+附件引用），payload SHA-256 随行；重跑出新版本并置旧版
--      SUPERSEDED——恢复/中断=重放, 回退=按身份删除包行(不动业务数据)。
--   3) 不改任何业务表、不搬移任何行、不删任何原文；热层读取路径零变化。

CREATE TABLE business_archive_eligibility (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_family    TEXT NOT NULL,
    object_id        UUID NOT NULL,
    evaluated_at     TIMESTAMPTZ NOT NULL,
    eligible         BOOLEAN NOT NULL,
    blocked_reasons  JSONB NOT NULL DEFAULT '[]'::jsonb,
    final_settled_on DATE,
    facts            JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT business_archive_eligibility_family_chk
        CHECK (object_family IN ('PURCHASE_ORDER')),
    CONSTRAINT uq_business_archive_eligibility_object
        UNIQUE (object_family, object_id)
);

CREATE INDEX idx_business_archive_eligibility_state
    ON business_archive_eligibility(eligible, evaluated_at DESC);

COMMENT ON TABLE business_archive_eligibility IS
    '归档资格评估登记(B3 试点)：只记录评估事实与阻碍原因, 不搬移不删除任何业务数据;'
    '资格=已审已结案+质量案件终结+收退单完结+台账全结清+结清满候选期(默认24个月,可配置)';

CREATE TABLE business_archive_packages (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_family    TEXT NOT NULL,
    object_id        UUID NOT NULL,
    package_version  INTEGER NOT NULL,
    policy_version   TEXT NOT NULL,
    payload          JSONB NOT NULL,
    payload_sha256   CHAR(64) NOT NULL,
    attachment_refs  JSONB NOT NULL DEFAULT '[]'::jsonb,
    line_counts      JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           TEXT NOT NULL DEFAULT 'VERIFIED'
                     CONSTRAINT business_archive_packages_status_chk
                     CHECK (status IN ('VERIFIED', 'SUPERSEDED')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    CONSTRAINT business_archive_packages_family_chk
        CHECK (object_family IN ('PURCHASE_ORDER')),
    CONSTRAINT uq_business_archive_packages_version
        UNIQUE (object_family, object_id, package_version)
);

CREATE INDEX idx_business_archive_packages_object
    ON business_archive_packages(object_family, object_id, status);

COMMENT ON TABLE business_archive_packages IS
    '业务对象完整归档快照包(B3 试点)：单事务一致快照内组装整族对象+原件引用, SHA-256 随行;'
    '包是可再生副本, 原始业务数据永远在线不动; 重跑出新版本并 supersede 旧版';

SELECT fn_audit_track_table('business_archive_eligibility','COLUMN_SCOPED','data_change',false,
    ARRAY['eligible','blocked_reasons','final_settled_on','evaluated_at'],true);
SELECT fn_audit_track_table('business_archive_packages','NONE','system',true);
