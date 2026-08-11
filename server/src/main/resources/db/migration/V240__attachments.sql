-- =====================================================================
-- V240：通用附件（attachments）—— 二进制存对象存储(OSS/本地盘)，本表只存 key 与元信息
-- =====================================================================
-- 背景：后端此前无任何文件/附件能力（报销无发票列、通知附件仅存文件名 JSON）。
--   本迁移只建通用附件元信息表；二进制不经数据库，由 StorageService 落对象存储：
--     · 本地开发：provider=local，写本地磁盘（LocalDiskStorageService）
--     · 生产/云端：provider=oss，阿里云 OSS 预签名 URL 直传直下（云端 ECS 用 RAM 角色免密钥）
--   owner_type/owner_id 软关联业务单据（如 'EXPENSE_CLAIM' = 报销单），不建硬外键以保持通用。
--   上传两阶段：presign(服务端生成 storage_key+上传URL) → 客户端直传 → confirm(校验对象存在+落库)。
-- 幂等：permissions ON CONFLICT；表新建。自包含、与既有 V150–V239 不交叉。
-- =====================================================================

CREATE TABLE attachments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_type      VARCHAR(64)  NOT NULL,
    owner_id        UUID         NOT NULL,
    -- 不透明存储键（UUID+扩展名，无斜杠），URL 安全；各后端内部映射到物理路径/OSS key。
    storage_key     VARCHAR(255) NOT NULL,
    original_name   VARCHAR(255) NOT NULL,
    content_type    VARCHAR(255),
    size_bytes      BIGINT       NOT NULL,
    sha256          VARCHAR(64),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,
    CONSTRAINT attachments_size_chk CHECK (size_bytes >= 0),
    CONSTRAINT attachments_owner_type_chk CHECK (length(owner_type) BETWEEN 1 AND 64),
    CONSTRAINT attachments_storage_key_chk CHECK (storage_key ~ '^[A-Za-z0-9._-]+$')
);

CREATE INDEX attachments_owner_idx     ON attachments (owner_type, owner_id);
CREATE INDEX attachments_created_by_idx ON attachments (created_by);

COMMENT ON TABLE  attachments IS '通用附件元信息；二进制存对象存储(OSS/本地盘)，本表只存 storage_key 与元信息';
COMMENT ON COLUMN attachments.owner_type IS '业务单据类型，如 EXPENSE_CLAIM（报销单）';
COMMENT ON COLUMN attachments.owner_id   IS '业务单据 id（软关联，不建外键以保持通用）';
COMMENT ON COLUMN attachments.storage_key IS '不透明存储键（UUID+扩展名，URL 安全，无斜杠）';
COMMENT ON COLUMN attachments.created_by IS '上传人 user_id（JPA 审计自动填充）';

-- ① 两个权限点（直接写 module + 规范 category，避免落入「其他」）。
INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('attachment:manage', '上传/删除附件', '人事行政', '附件', 231),
    ('attachment:view',   '查看/下载附件', '人事行政', '附件', 232)
ON CONFLICT (code) DO UPDATE
SET name      = EXCLUDED.name,
    module     = EXCLUDED.module,
    category   = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- ② 财务部（DEPT_FIN，审批/打款报销需看发票）：管理 + 查看。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_FIN'
  AND d.is_deleted = FALSE
  AND p.code IN ('attachment:manage', 'attachment:view')
ON CONFLICT DO NOTHING;

-- ③ 能申请报销的部门 → 可上传/删除附件（applicant 上传发票）；能审批报销的部门 → 可查看。
-- 复用既有授权：凡持 expense:apply 的部门补 attachment:manage+view；持 expense:approve 的部门补 attachment:view。
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p.id
FROM department_permissions dp
JOIN permissions ep ON ep.id = dp.permission_id AND ep.code = 'expense:apply'
CROSS JOIN permissions p
WHERE p.code IN ('attachment:manage', 'attachment:view')
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p.id
FROM department_permissions dp
JOIN permissions ep ON ep.id = dp.permission_id AND ep.code = 'expense:approve'
CROSS JOIN permissions p
WHERE p.code = 'attachment:view'
ON CONFLICT DO NOTHING;
