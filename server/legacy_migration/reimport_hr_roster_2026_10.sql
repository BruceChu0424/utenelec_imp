-- =====================================================================
-- 2026-10 人事重导·方案二（2026-10-09 用户指令，单事务）：
--   人事「公司人员」= 2026-10《花名册.xls》141 人 + 系统管理员(ADMIN/17665410007)；
--   全库仅保留 ADMIN 一个登录账号（原 6 个已开账号按用户指令一并中和，不再重开）。
-- ---------------------------------------------------------------------
-- 背景与方案选择：
--   · 库内 employment_history / employee_offboarding_events /
--     client_access_change_events 均 55000 append-only（2026-08 之后加的守卫），
--     2026-08 那套「硬删 + 重插」管线已物理不可行；
--   · 本脚本改为「身份对齐就地更新」：
--       §G 名册 141 人按身份证哈希匹配既有员工行 → 同一行更新成名册口径
--         （工号 UT0002..UT0142 不变、敏感信息/轨迹不动、王少春=UT0009 等全保连续）；
--       §J 名册外员工（老库桩/测试号/离职者，≈72 行）全部软删（is_deleted+resigned）；
--       §K 非 ADMIN 的在册账号全部中和（offboarded-改名+disabled+软删，沿用
--         2026-10-09 王少春旧账号处置配方）；
--       §N 软删旧桩名下的客户/货品归属改挂到名册真身（证件哈希→姓名+手机→同名
--         三级兜底；人不在册者置 NULL 待 HR 重指派）；
--       §K2 名册未覆盖的部门负责人清空（本次=PMC运营仓储部，庞宗荣职级经理→职工）。
--   · 名册与 2026-08 版逐字段 diff：仅 庞宗荣 职级变化 与 王少春 入职时间空白
--     （已按 8 月值 2007-01-12 回填，见 build_hr_roster.py HIRE_BACKFILL），其余全同。
-- 执行（密钥不经终端：.env 由 docker cp 进容器，SQL 内 pg_read_file 服务端解析）：
--   docker cp data/hr_roster.csv data/hr_managers.csv ../.env → 容器 /tmp/uten_env.tmp 等
--   docker exec -i -e PGOPTIONS=<log 抑制+UTF8> uten-imp-postgres psql -X
--     -v ON_ERROR_STOP=1 -U uten -d uten_imp < 本文件
-- 单事务：任何一步失败整体回滚。
-- =====================================================================

BEGIN;
SET LOCAL standard_conforming_strings = on;
-- 与官方 migrate.sh run_sql 同口径：导入会话旁路逐行审计（ADR-105）
SET LOCAL app.legacy_import = 'on';
SELECT set_config('app.employee_pii_extra_legacy_import', 'v1', true);
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- 与 V282 JVM 回填/证件核对 Runner 串行（沿用 2026-08 名录迁移的锁键）
SELECT pg_advisory_xact_lock(1431586126, 282);

-- ---------------- 密钥装载（服务端解析 /tmp/uten_env.tmp；值不进终端/日志） ----------------
CREATE TEMP TABLE ck AS
SELECT
  COALESCE(btrim((regexp_match(pg_read_file('/tmp/uten_env.tmp'), '(^|\n)[ \t]*UTEN_PGP_MASTER_KEY[ \t]*=[ \t]*([^\r\n#]*)'))[2]), '') AS pgp_key,
  COALESCE(btrim((regexp_match(pg_read_file('/tmp/uten_env.tmp'), '(^|\n)[ \t]*UTEN_HMAC_KEY[ \t]*=[ \t]*([^\r\n#]*)'))[2]), '') AS hmac_key,
  COALESCE(NULLIF(btrim((regexp_match(pg_read_file('/tmp/uten_env.tmp'), '(^|\n)[ \t]*UTEN_PGP_KEY_VERSION[ \t]*=[ \t]*([^\r\n#]*)'))[2]), ''), '1') AS pgp_ver;

DO $$ BEGIN
    IF (SELECT pgp_key = '' OR hmac_key = '' FROM ck) THEN
        RAISE EXCEPTION '/tmp/uten_env.tmp 缺少 UTEN_PGP_MASTER_KEY 或 UTEN_HMAC_KEY';
    END IF;
END $$;

-- ---------------- 名册 staging ----------------
CREATE TEMP TABLE hr_roster (
    emp_code text, seq int, full_name text, gender text, political_status text,
    birth_date text, hire_date text, dept_code text, pos_name text, pos_level text,
    id_card text, phone text, huji text, residence text,
    note text, confirmed_at text, base_salary text, allowance_standard text);
\copy hr_roster FROM '/tmp/hr_roster.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE hr_mgr (dept_code text, emp_code text);
\copy hr_mgr FROM '/tmp/hr_managers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- staging 闸门：141 人、工号/证件唯一、部门全部可解析、入职日期非空
DO $$
BEGIN
    IF (SELECT count(*) FROM hr_roster) <> 141 THEN
        RAISE EXCEPTION '名册行数应为 141，实际 %', (SELECT count(*) FROM hr_roster);
    END IF;
    IF (SELECT count(DISTINCT emp_code) FROM hr_roster) <> 141 THEN
        RAISE EXCEPTION '名册工号有重复';
    END IF;
    IF EXISTS (SELECT 1 FROM hr_roster
               WHERE NULLIF(btrim(id_card), '') IS NOT NULL
               GROUP BY btrim(id_card) HAVING count(*) > 1) THEN
        RAISE EXCEPTION '名册身份证号有重复';
    END IF;
    IF (SELECT count(*) FROM hr_roster s JOIN departments d ON d.code = s.dept_code) <> 141 THEN
        RAISE EXCEPTION '名册存在无法解析的部门 code';
    END IF;
    IF EXISTS (SELECT 1 FROM hr_roster WHERE btrim(hire_date) = '') THEN
        RAISE EXCEPTION '名册存在空入职日期（请先在 build_hr_roster.py HIRE_BACKFILL 登记回填）';
    END IF;
END $$;

-- ---------------- 身份匹配：名册人 → 既有员工行（工号直配；2026-10 名册工号与库内现行工号同源同序） ----------------
CREATE TEMP TABLE roster_match AS
SELECT s.emp_code, s.full_name,
       (SELECT e.id FROM employees e
         WHERE e.code = s.emp_code AND e.is_deleted = false) AS emp_id
FROM hr_roster s;

-- 匹配闸门：141 人全部命中在档行，且行上姓名与名册一致（错配/漏配即中止人工核对）
DO $$
DECLARE miss int; name_mismatch int;
BEGIN
    SELECT count(*) FILTER (WHERE emp_id IS NULL),
           count(*) FILTER (WHERE emp_id IS NOT NULL
                            AND (SELECT full_name FROM employees WHERE id = emp_id) <> full_name)
      INTO miss, name_mismatch
      FROM roster_match;
    IF miss <> 0 OR name_mismatch <> 0 THEN
        RAISE EXCEPTION '工号匹配异常：未命中 % 人，姓名不一致 % 人（中止，请人工核对名册工号映射）', miss, name_mismatch;
    END IF;
END $$;

-- ---------------- §G 岗位：按 (岗位名称 × 部门) 建档，缺则新建，有则复用并按名册刷新职级 ----------------
WITH need AS (
    SELECT DISTINCT s.pos_name, s.pos_level, d.id AS department_id, d.code AS dept_code
    FROM hr_roster s
    JOIN departments d ON d.code = s.dept_code
    WHERE NOT EXISTS (
        SELECT 1 FROM positions p
        WHERE p.department_id = d.id AND p.name = s.pos_name AND p.is_deleted = false)
), numbered AS (
    SELECT need.*,
           'ZW' || lpad((actual.m + row_number() OVER (ORDER BY need.dept_code, need.pos_name))::text, 4, '0') AS new_code
    FROM need
    CROSS JOIN (SELECT COALESCE(MAX(substring(code FROM 3)::int), 0) AS m
                FROM positions WHERE code ~ '^ZW[0-9]+$') actual
)
INSERT INTO positions (code, name, level, department_id, sort_order)
SELECT new_code, pos_name, pos_level, department_id, 100 FROM numbered
ON CONFLICT (code, department_id) DO NOTHING;

UPDATE positions p
SET level = s.pos_level
FROM (SELECT DISTINCT pos_name, pos_level, dept_code FROM hr_roster) s
JOIN departments d ON d.code = s.dept_code
WHERE p.department_id = d.id AND p.name = s.pos_name AND p.level IS DISTINCT FROM s.pos_level;

UPDATE master_code_sequences
SET last_seq = GREATEST(last_seq,
    (SELECT COALESCE(MAX(substring(code FROM 3)::int), 0) FROM positions WHERE code ~ '^ZW[0-9]+$'))
WHERE prefix = 'ZW';

-- ---------------- §H 名册 141 人就地更新（工号/行/敏感信息全保留，字段对齐名册） ----------------
-- 注意：不动 birth_date/political_status/huji_address/residence_address 明文列（真值在
-- employee_sensitive.*_enc，2026-10 名册与库内值无差异），也不动 supervisor_id/加密行。
UPDATE employees e
SET full_name        = s.full_name,
    gender           = NULLIF(s.gender, ''),
    id_type          = CASE WHEN NULLIF(s.id_card, '') IS NOT NULL THEN '身份证' ELSE '其他' END,
    department_id    = d.id,
    position_id      = p.id,
    hire_date        = s.hire_date::date,
    confirmed_at     = COALESCE(NULLIF(s.confirmed_at, '')::date, s.hire_date::date),
    status           = 'active',
    employment_type  = 'regular',
    is_deleted       = false,
    deleted_at       = NULL,
    legacy_category  = 'HR正式名录2026-10'
FROM roster_match m
JOIN hr_roster s ON s.emp_code = m.emp_code
JOIN departments d ON d.code = s.dept_code
LEFT JOIN positions p ON p.department_id = d.id AND p.name = s.pos_name AND p.is_deleted = false
WHERE e.id = m.emp_id;

-- 同步 UT 序列（防御；本次无新工号）
UPDATE master_code_sequences
SET last_seq = GREATEST(last_seq,
    (SELECT COALESCE(MAX(substring(code FROM 3)::int), 0) FROM employees WHERE code ~ '^UT[0-9]+$'))
WHERE prefix = 'UT';

-- ---------------- §J 名册外员工全部软删（老库桩/测试号/离职者；append-only 守卫下唯一合规出口） ----------------
UPDATE employees
SET is_deleted = true,
    deleted_at = now(),
    status = 'resigned'
WHERE code <> 'ADMIN'
  AND id NOT IN (SELECT emp_id FROM roster_match)
  AND is_deleted = false;

-- ---------------- §K 非 ADMIN 在册账号全部中和（改名释放登录名+禁用+软删） ----------------
-- users.login_account 全表唯一（含已删行）：与既有 offboarded-* 撞名时追加确定性后缀消歧
UPDATE users u
SET login_account        = 'offboarded-' || u.login_account
                         || CASE WHEN EXISTS (SELECT 1 FROM users x
                                              WHERE x.login_account = 'offboarded-' || u.login_account
                                                AND x.id <> u.id)
                                 THEN '-' || substr(md5(u.id::text), 1, 6) ELSE '' END,
    is_deleted           = true,
    status               = 'disabled',
    remote_access        = false,
    must_change_password = true,
    temp_password_expires_at = now()
WHERE u.is_deleted = false
  AND u.employee_id <> (SELECT id FROM employees WHERE code = 'ADMIN');

-- ---------------- §K2 部门负责人：按名册指派 + 清空名册未覆盖的部门 ----------------
UPDATE departments d
SET manager_id = e.id
FROM hr_mgr m
JOIN employees e ON e.code = m.emp_code
WHERE d.code = m.dept_code
  AND d.manager_id IS DISTINCT FROM e.id;

UPDATE departments d
SET manager_id = NULL
WHERE d.code NOT IN (SELECT dept_code FROM hr_mgr)
  AND d.manager_id IS NOT NULL;

-- ---------------- §L 任职轨迹：名册为权威来源，缺 onboard 行的补写（应 0 行） ----------------
INSERT INTO employment_history (employee_id, event_type, to_dept_id, to_position_id, event_date, remark)
SELECT e.id, 'onboard', e.department_id, e.position_id, e.hire_date,
       'HR正式名录导入(2026-10)：入职时间以《职工个人信息表》为准'
FROM employees e
JOIN roster_match m ON m.emp_id = e.id
JOIN hr_roster s ON s.emp_code = m.emp_code
WHERE NOT EXISTS (
    SELECT 1 FROM employment_history h
    WHERE h.employee_id = e.id AND h.event_type = 'onboard' AND h.event_date = e.hire_date);

-- ---------------- §M headcount 重算（在档且未删） ----------------
UPDATE departments d SET headcount = 0 WHERE headcount <> 0;
UPDATE departments d
SET headcount = sub.cnt
FROM (SELECT department_id, count(*) AS cnt
      FROM employees
      WHERE is_deleted = false AND status <> 'resigned'
      GROUP BY department_id) sub
WHERE d.id = sub.department_id;

-- ---------------- §N 软删旧桩名下的客户/货品归属改挂名册真身（三级兜底） ----------------
-- 名册内员工自有的归属引用（如 UT0006/UT0011/UT0048/UT0141）不动；只处理指向软删行的引用。
CREATE TEMP TABLE stub_owner_map AS
SELECT DISTINCT e.id AS old_id, e.full_name, s.id_card_hash, s.phone_hash,
       (SELECT count(*) FROM clients c WHERE c.owner_employee_id = e.id) AS n_clients,
       (SELECT count(*) FROM goods g WHERE g.owner_employee_id = e.id) AS n_goods_owner,
       (SELECT count(*) FROM goods g WHERE g.owning_responsible_employee_id = e.id) AS n_goods_resp
FROM employees e
LEFT JOIN employee_sensitive s ON s.employee_id = e.id
WHERE e.code <> 'ADMIN'
  AND e.is_deleted = true
  AND (EXISTS (SELECT 1 FROM clients c WHERE c.owner_employee_id = e.id)
    OR EXISTS (SELECT 1 FROM goods g WHERE g.owner_employee_id = e.id)
    OR EXISTS (SELECT 1 FROM goods g WHERE g.owning_responsible_employee_id = e.id));

CREATE TEMP TABLE stub_remap AS
SELECT m.old_id, m.full_name,
       (SELECT e2.id FROM employees e2
          JOIN employee_sensitive s2 ON s2.employee_id = e2.id
         WHERE m.id_card_hash IS NOT NULL AND s2.id_card_hash = m.id_card_hash
           AND e2.is_deleted = false AND e2.status IN ('active', 'probation', 'onLeave')
         LIMIT 1) AS by_id,
       (SELECT e2.id FROM employees e2
          JOIN employee_sensitive s2 ON s2.employee_id = e2.id
         WHERE e2.full_name = m.full_name
           AND m.phone_hash IS NOT NULL AND s2.phone_hash = m.phone_hash
           AND e2.is_deleted = false AND e2.status IN ('active', 'probation', 'onLeave')
         LIMIT 1) AS by_name_phone,
       (SELECT e2.id FROM employees e2
         WHERE e2.full_name = m.full_name
           AND e2.is_deleted = false AND e2.status IN ('active', 'probation', 'onLeave')
           AND e2.legacy_category = 'HR正式名录2026-10'
         LIMIT 1) AS by_full_name
FROM stub_owner_map m;

ALTER TABLE stub_remap ADD COLUMN new_id uuid;
UPDATE stub_remap SET new_id = COALESCE(by_id, by_name_phone, by_full_name);

UPDATE clients c SET owner_employee_id = r.new_id
FROM stub_remap r
WHERE c.owner_employee_id = r.old_id AND r.new_id IS NOT NULL;

UPDATE goods g SET owner_employee_id = r.new_id
FROM stub_remap r
WHERE g.owner_employee_id = r.old_id AND r.new_id IS NOT NULL;

UPDATE goods g SET owning_responsible_employee_id = r.new_id
FROM stub_remap r
WHERE g.owning_responsible_employee_id = r.old_id AND r.new_id IS NOT NULL;

-- 仍指向软删行且无同名真身可挂的归属 → 置 NULL（人已不在册，HR 后续重新指派）
UPDATE clients SET owner_employee_id = NULL
WHERE owner_employee_id IN (SELECT id FROM employees WHERE is_deleted = true);
UPDATE goods SET owner_employee_id = NULL
WHERE owner_employee_id IN (SELECT id FROM employees WHERE is_deleted = true);
UPDATE goods SET owning_responsible_employee_id = NULL
WHERE owning_responsible_employee_id IN (SELECT id FROM employees WHERE is_deleted = true);

COMMIT;

-- ================= 校验与报告（只读） =================
SELECT '✔ 在档员工(应142=141名册+ADMIN): ' || count(*) FROM employees WHERE is_deleted = false
UNION ALL SELECT '名册口径员工(应141): ' || count(*) FROM employees WHERE legacy_category = 'HR正式名录2026-10' AND is_deleted = false
UNION ALL SELECT '在档非active(应0): ' || count(*) FROM employees WHERE is_deleted = false AND status <> 'active'
UNION ALL SELECT '登录账号(应仅1=17665410007): ' || count(*) || ' → ' || COALESCE(string_agg(login_account, ','), '') FROM users WHERE is_deleted = false
UNION ALL SELECT '被中和账号(应6): ' || count(*) FROM users WHERE login_account LIKE 'offboarded-%'
UNION ALL SELECT '部门负责人已设: ' || count(*) FROM departments WHERE manager_id IS NOT NULL
UNION ALL SELECT 'SUB_WH负责人(应空): ' || count(*) FROM departments WHERE code = 'SUB_WH' AND manager_id IS NOT NULL
UNION ALL SELECT '客户归属挂软删行(应0): ' || count(*) FROM clients c JOIN employees e ON e.id = c.owner_employee_id WHERE e.is_deleted = true
UNION ALL SELECT '客户归属悬空(人不在册): ' || count(*) FROM clients WHERE owner_employee_id IS NULL
UNION ALL SELECT '货品归属挂软删行(应0): ' || count(*) FROM goods g JOIN employees e ON e.id = g.owner_employee_id WHERE e.is_deleted = true
UNION ALL SELECT '货品负责归属挂软删行(应0): ' || count(*) FROM goods g JOIN employees e ON e.id = g.owning_responsible_employee_id WHERE e.is_deleted = true;

-- 归属未回接清单（人不在册，其名下客户/货品已置 NULL → HR 需重新指派）
SELECT m.full_name AS 不在册原归属人,
       m.n_clients AS 客户数, m.n_goods_owner AS 货品归属数, m.n_goods_resp AS 货品负责数
FROM stub_owner_map m
JOIN stub_remap r ON r.old_id = m.old_id
WHERE r.new_id IS NULL
ORDER BY m.n_clients DESC, m.n_goods_owner DESC;

-- 部门分布对照
SELECT d.code, d.name, d.headcount,
       (SELECT count(*) FROM employees e WHERE e.department_id = d.id AND e.is_deleted = false) AS actual
FROM departments d
WHERE d.id IN (SELECT DISTINCT department_id FROM employees WHERE is_deleted = false)
ORDER BY d.path;

-- 负责人一览
SELECT d.code, d.name AS dept, e.code AS mgr_code, e.full_name AS manager
FROM departments d JOIN employees e ON e.id = d.manager_id
ORDER BY d.path;

-- 与 2026-08 的差异抽查：庞宗荣(职级变化) + 王少春(入职回填) + 账号持有者档案连续性
SELECT e.code, e.full_name, d.name AS dept, p.name AS pos, p.level, e.hire_date, e.status
FROM employees e
JOIN departments d ON d.id = e.department_id
LEFT JOIN positions p ON p.id = e.position_id
WHERE e.full_name IN ('庞宗荣', '王少春', '胡钟炎', '李桃秀', '石磊', '韩焕超', '李中禄')
ORDER BY e.code;
