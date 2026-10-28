-- 模板持续绑定（2026-10-27 用户口径：模板修改后，应用该模板的人自动跟着变）。
-- 应用模板时记录「该账号最近应用的模板」，模板保存后按差量同步到全部绑定账号：
-- 模板新增的码补个人加授（个人收回优先，不被覆盖；继承来源已生效的不重复加授），
-- 模板移除的码清掉对应个人加授。复制/导入他人权限会解除关联（配置不再源于模板）。
-- 一人只保留最近一次应用的绑定；模板软删时显式清除其绑定行。
CREATE TABLE permission_template_applies (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    template_id uuid NOT NULL REFERENCES permission_templates(id) ON DELETE CASCADE,
    applied_version bigint NOT NULL CHECK (applied_version >= 0),
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by uuid NOT NULL REFERENCES users(id)
);
CREATE INDEX permission_template_applies_template_idx ON permission_template_applies(template_id);
COMMENT ON TABLE permission_template_applies IS '最近应用某权限模板的账号；模板保存后差量同步（个人收回优先），复制/导入权限解除关联';
SELECT fn_audit_track_table('permission_template_applies','FULL','authorization',false);
