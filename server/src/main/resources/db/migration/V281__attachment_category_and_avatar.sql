-- =====================================================================
-- V281：附件分类列 + 员工头像引用列
-- =====================================================================
-- 背景：员工档案文件需分类（合同/身份证件/学历证书/照片/其他），且员工头像要落地。
--   attachments.category：文档分类（应用层枚举校验，DB 仅存字符串；nullable 兼容旧报销附件）。
--   attachments.is_avatar：标记该附件为员工头像（同员工至多一条，由应用层保证）。
--   employees.avatar_storage_key：头像 storage_key 冗余列，避免花名册列表逐行查附件 N+1。
-- 幂等：IF NOT EXISTS；自包含，与 V240/V243/V244/V255 不交叉。
-- =====================================================================

ALTER TABLE attachments
    ADD COLUMN IF NOT EXISTS category  VARCHAR(48),
    ADD COLUMN IF NOT EXISTS is_avatar BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE employees
    ADD COLUMN IF NOT EXISTS avatar_storage_key VARCHAR(255);

COMMENT ON COLUMN attachments.category  IS '文档分类：合同/身份证件/学历证书/照片/其他（员工档案）；报销附件为 NULL';
COMMENT ON COLUMN attachments.is_avatar IS '是否作为员工头像（同员工至多一条，由应用层保证）';
COMMENT ON COLUMN employees.avatar_storage_key IS '员工头像 storage_key 冗余（避免列表 N+1）；为空则用首字头像';

-- 头像查询索引：仅 is_avatar=TRUE 的行参与，定位同员工头像很快。
CREATE INDEX IF NOT EXISTS attachments_avatar_idx
    ON attachments (owner_type, owner_id) WHERE is_avatar = TRUE;
