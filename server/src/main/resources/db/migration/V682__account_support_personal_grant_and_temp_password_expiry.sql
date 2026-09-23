-- V682 账号支持改为个人点名授权 + 存量临时密码置为过期 (ADR-110; security-01/02)
--
-- 1) account:support 可以重置任意非超管账号的密码并拿到明文临时密码, 原先整个
--    「行政与人力资源部」都有。改为只能个人点名授予:
--    - 删除全部部门级授予 (负责人委派同样删除);
--    - 授权策略 permissions.grant_policy (V677 起的唯一事实源, ADR-109) 改为 INDIVIDUAL_ONLY:
--      不进部门矩阵、不可委派、不随批量, 只能由超管在「个人授权」里点名配置;
--      部门侧由服务 (GrantPolicy) 与通用守卫 fn_guard_permission_grant_policy 双重拒绝,
--      不再单独维护按码写死的守卫函数。
-- 2) 初始密码过去由身份证后 6 位推导且永不过期; 现在统一随机高熵 + 有效期。
--    存量「必须改密但没有过期时间」的非超管账号一律置为已过期, 需重新发放临时密码。
--    超级管理员除外: 引导管理员的初始密码来自部署密钥而非个人信息, 置过期会让系统无人可管。
--    随后加触发器 trg_users_temp_password_expiry: 任何写路径 (离职冻结、复职、交接加固、超管降级、
--    将来新增的) 写出「必须改密却没有过期时间」的非超管账号时, 一律按已过期落库 (失败关闭:
--    这张临时凭据立即不可用, 需重新发放)。不用 CHECK 约束: users.must_change_password 的列默认值是
--    TRUE, 大量只为占位建号的原生 INSERT 不写这两列, CHECK 会让它们全部报错; 触发器给出同样的保证
--    ——库里永远不存在永久有效的临时凭据。离职/复职在代码里也显式把旧密码置为已过期。
-- 3) permissions.high_risk: 持有者的登录凭据 (重置临时密码、给存量员工补开账号) 只能由超级管理员
--    发放。清单在这里集中维护, 代码只读标记 (CredentialIssuancePolicy):
--    - V212 「高危/个人-only」清单与授权管理、账号支持本身、账户余额调整;
--    - 财税模块全部审批/执行类权限 (付款、收款、转账、费用、其它收入的审批与冲销, 过账, 预收/对冲/结算…);
--    - 报销审批与付款, 工资生成/审核/发布与查看全员工资。

DELETE FROM department_permissions dp
USING permissions p
WHERE dp.permission_id = p.id
  AND p.code = 'account:support';

-- V677 已把 account:support 标为 NON_DELEGABLE, 正常不会有委派行; 仍显式清掉, 保证与新策略一致。
DELETE FROM manager_permission_delegations delegation
USING permissions p
WHERE delegation.permission_id = p.id
  AND p.code = 'account:support';

UPDATE permissions
SET grant_policy = ARRAY['INDIVIDUAL_ONLY']::TEXT[],
    description = '账号支持: 开通、锁定、启停、解锁及重置登录账号 (只能个人点名授权; 目标持有高危权限时只有超管能重置密码或开通账号)'
WHERE code = 'account:support';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code = 'account:support' AND grant_policy = ARRAY['INDIVIDUAL_ONLY']::TEXT[]) THEN
        RAISE EXCEPTION 'V682 account:support must exist and be INDIVIDUAL_ONLY';
    END IF;
END;
$$;

UPDATE users
SET temp_password_expires_at = now()
WHERE must_change_password
  AND temp_password_expires_at IS NULL
  AND NOT is_super_admin;

CREATE FUNCTION fn_users_temp_password_expiry()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.must_change_password
       AND NOT NEW.is_super_admin
       AND NEW.temp_password_expires_at IS NULL THEN
        NEW.temp_password_expires_at := now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_temp_password_expiry
    BEFORE INSERT OR UPDATE OF must_change_password, is_super_admin, temp_password_expires_at
    ON users
    FOR EACH ROW
    EXECUTE FUNCTION fn_users_temp_password_expiry();

COMMENT ON FUNCTION fn_users_temp_password_expiry() IS
    '临时凭据不得永不过期 (ADR-110): 必须改密的非超管账号没有过期时间时按已过期落库';
COMMENT ON COLUMN users.temp_password_expires_at IS
    '临时密码有效期截止 (系统设置「临时密码有效期」); 必须改密的非超管账号写空即按已过期落库 (trg_users_temp_password_expiry), 离职/复职即置为当前时刻使旧密码作废; 本人改密成功后清空';

ALTER TABLE permissions
    ADD COLUMN high_risk BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN permissions.high_risk IS
    '高危权限: 持有者的登录凭据 (重置临时密码、补开账号) 只能由超级管理员发放, 防止账号支持人员借明文临时密码冒充审批/付款人 (ADR-110)';

UPDATE permissions
SET high_risk = TRUE
WHERE code IN (
        'audit_log:view', 'audit_log:export',
        'authorization:manage', 'user:manage', 'workflow_assignment:manage',
        'account:support',
        'stock:balance:adjust', 'account:balance:adjust',
        'finance_asset:approve', 'finance_asset:post', 'finance_asset:dispose',
        'finance_asset:export', 'finance_asset_period:manage',
        'expense:approve', 'expense:pay',
        'payroll:generate', 'payroll:review', 'payroll:publish', 'payroll:view:all')
   OR (module = '财税管理' AND action_type IN ('APPROVE', 'EXECUTE'));
