-- =====================================================================
-- V958：公司资料库权限简化——入口开关 + 目录级授权（ADR-194 2026-10-27 修订）
-- =====================================================================
-- 产品口径（取代 V931「入口按部门显式分配」的决定）：
--   1) 常用模块只剩一个入口开关：company_file:view 回归全员基础包，与其他常用
--      模块（报销/工资条/意见箱）同款——默认全员可见，可按账号单独收回。
--   2) 可见即可下载：company_file:download 退役；下载/预览随入口与目录范围走，
--      目录可用拒绝规则单独禁止下载。
--   3) 上传/新建/编辑/移动/删除/还原/授权 7 个写码移出「常用模块」，归入
--      「系统管理」：默认无人持有，作为全局资料管理员授权保留；同时目录 ACL
--      的允许规则本身即生效（不再要求被授权人另持系统码）。
--   4) 目录 ACL 新增『所有人』占位主体 subject_type='ALL'（固定零 UUID，
--      仅允许 view+download、仅 ALLOW），供新建/设置弹窗表达「所有人可以看」。
--   5) V931 按部门补发的入口分配在 baseline 下成为冗余配置，按迁移先例清理；
--      个人收回与其他部门配置不受影响。
-- =====================================================================

UPDATE permissions SET baseline=true,
    description='显示资料库入口并查看资料；默认全员可见，可按账号收回。目录可单独设置可见范围。'
    WHERE code='company_file:view';

-- 写操作码离开常用模块（工作台自助卡片区只保留入口码）。
UPDATE permissions SET module='系统管理',
    description='全局资料管理：在任意授权目录上传新文件，需通过统一安全扫描；具体目录也可按规则单独授予。'
    WHERE code='company_file:upload';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：在任意授权目录新建文件夹；具体目录也可按规则单独授予。'
    WHERE code='company_file:create';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：重命名或编辑授权目录及文件的说明；具体目录也可按规则单独授予。'
    WHERE code='company_file:edit';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：移动授权文件或目录并调整目录内顺序；具体目录也可按规则单独授予。'
    WHERE code='company_file:move';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：将授权文件或整棵目录移入回收站，原件保留；具体目录也可按规则单独授予。'
    WHERE code='company_file:delete';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：还原授权回收站内容；具体目录也可按规则单独授予。'
    WHERE code='company_file:restore';
UPDATE permissions SET module='系统管理',
    description='全局资料管理：按用户或部门设置目录授权及密码保护；需本人登录密码再认证；具体目录也可按规则单独授予。'
    WHERE code='company_file:manage_permissions';

-- 常用模块面板（页面内授权面）只绑定入口码。
DELETE FROM permission_surface_permissions link
    USING permissions permission
    WHERE link.permission_id=permission.id
      AND permission.code LIKE 'company_file:%'
      AND permission.code <> 'company_file:view';

-- 下载码退役：可见即可下载（目录拒绝规则仍可单禁下载）。
DELETE FROM manager_permission_delegations delegation
    USING permissions permission
    WHERE delegation.permission_id=permission.id AND permission.code='company_file:download';
DELETE FROM user_permission_overrides override
    USING permissions permission
    WHERE override.permission_id=permission.id AND permission.code='company_file:download';
DELETE FROM department_permissions allocation
    USING permissions permission
    WHERE allocation.permission_id=permission.id AND permission.code='company_file:download';
DELETE FROM permission_surface_permissions link
    USING permissions permission
    WHERE link.permission_id=permission.id AND permission.code='company_file:download';
DELETE FROM permissions WHERE code='company_file:download';

-- baseline=true 后入口人人可见；部门分配只保留会误导权限页（新部门也不会再补发）。
DELETE FROM department_permissions allocation
    USING permissions permission
    WHERE allocation.permission_id=permission.id AND permission.code='company_file:view';

-- 精确替换 V925 的 subject_type 列 CHECK（沿用 V931 的表达式核对法，防串线）。
DO $acl_subject_contract$
DECLARE expected text; matching text[];
BEGIN
    CREATE TEMP TABLE company_file_acl_subject_contract (
        subject_type text CHECK(subject_type IN ('USER','DEPARTMENT'))
    ) ON COMMIT DROP;
    SELECT pg_get_expr(conbin,conrelid) INTO STRICT expected FROM pg_constraint
        WHERE conrelid='pg_temp.company_file_acl_subject_contract'::regclass AND contype='c';
    SELECT array_agg(conname ORDER BY conname) INTO matching FROM pg_constraint
        WHERE conrelid='public.company_file_acl'::regclass AND contype='c'
          AND pg_get_expr(conbin,conrelid)=expected;
    IF cardinality(matching) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'Unreviewed company file ACL subject constraint; everyone upgrade refused' USING ERRCODE='23514';
    END IF;
    EXECUTE format('ALTER TABLE public.company_file_acl DROP CONSTRAINT %I',matching[1]);
END $acl_subject_contract$;
ALTER TABLE company_file_acl ADD CONSTRAINT company_file_acl_subject_check
    CHECK ((subject_type IN ('USER','DEPARTMENT'))
        OR (subject_type='ALL' AND subject_id='00000000-0000-0000-0000-000000000000'::uuid
            AND effect='ALLOW' AND cardinality(actions)>0
            AND actions <@ ARRAY['view','download']::text[]));

COMMENT ON CONSTRAINT company_file_acl_subject_check ON company_file_acl IS
    'ALL=所有人占位主体(V958)：固定零 UUID，仅 ALLOW 且只含 view/download；数据库兜底，服务端仍完整校验';
