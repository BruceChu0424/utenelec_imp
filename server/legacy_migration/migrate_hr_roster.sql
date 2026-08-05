-- =====================================================================
-- HR 正式名录迁移：中山市优腾电器职工信息表.xls（141 人）→ employees + positions
--   + employee_sensitive + employment_history(onboard) + departments.manager_id/headcount
-- =====================================================================
-- 用法：
--   1. python server/legacy_migration/build_hr_roster.py   # xls → data/hr_roster.csv + hr_managers.csv
--   2. bash server/legacy_migration/migrate.sh --hr-cleanup --confirm-destructive   # 清理到只剩 admin
--   3. bash server/legacy_migration/migrate.sh --hr-roster  --confirm-destructive   # 正式名录导入
-- 设计（与 docs/数据迁移/53-人事正式名录迁移.md 一致）：
--   · 工号：表内全空 → 构建脚本按序号编 UT0002..（UT0001 为已删测试员工，不复用）；
--     幂等键 = employees.code（ON CONFLICT upsert），导入后同步 master_code_sequences。
--   · 高层（常务副总经理/副总经理）→ 挂总经办 GM、岗位职级=领导层；其「兼职部门领导」
--     经 departments.manager_id 表达（管理中心负责人，厂长另兼生产部），不复制员工行。
--   · 经理 → 领导层（部门经理/运营经理/营销经理）；拉长/领班 → 班组管理；其余 → 员工。
--   · 岗位按 (岗位名称 × 部门) 建档：同名同部门已存在则复用（并补 level），否则按 ZW 序列新建。
--   · 工龄：不入库，系统按 hire_date 动态计算（员工列表/详情页显示「X 年 Y 个月」）。
--   · 敏感信息：身份证/手机 pgcrypto 加密 + HMAC 查重哈希，与服务端同口径
--     （密钥经 /tmp/_uten_keys.sql 注入，migrate.sh 用后即时删除）。
--   · 入职事件：名册为权威来源，按 hire_date 写 onboard 轨迹（重跑按 (员工,onboard,日期) 去重）。
-- 安全闸：若现有 UT 工号员工与名册姓名冲突且非本迁移所建，立即中止（提示先 --hr-cleanup）。
-- =====================================================================

-- 注入密钥变量（:pgp_key / :pgp_ver / :hmac_key），文件由 migrate.sh 生成、用后删除
\i /tmp/_uten_keys.sql

BEGIN;
SET session_replication_role = replica;

-- ---------------- staging ----------------
CREATE TEMP TABLE hr_roster (
    emp_code text, seq int, full_name text, gender text, political_status text,
    birth_date text, hire_date text, dept_code text, pos_name text, pos_level text,
    id_card text, phone text, huji text, residence text);
\copy hr_roster FROM '/tmp/hr_roster.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE hr_mgr (dept_code text, emp_code text);
\copy hr_mgr FROM '/tmp/hr_managers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- 安全闸：与现有非本迁移 UT 员工冲突则中止 ----------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM employees e
        JOIN hr_roster s ON s.emp_code = e.code
        WHERE e.full_name <> s.full_name
          AND COALESCE(e.legacy_category, '') <> 'HR正式名录2026-08'
    ) THEN
        RAISE EXCEPTION '现有 UT 工号员工与正式名录冲突，请先执行 --hr-cleanup 或人工核对后再导入';
    END IF;
END $$;

-- ---------------- §0 部门改名（与名录口径对齐；code 一律不动，path 触发器自动维护） ----------------
-- 五金铜铸车间为表内笔误：老库 B_WorkShop(39=铜柱车间)/委外内部车间/成本核算附件7 均为「铜柱」，不改名。
UPDATE departments SET name = '财税与行政管理中心' WHERE code = 'FIN_CENTER' AND name <> '财税与行政管理中心';
UPDATE departments SET name = '财务部'           WHERE code = 'DEPT_FIN'   AND name <> '财务部';
UPDATE departments SET name = '综合营销事业部'     WHERE code = 'DEPT_SALES' AND name <> '综合营销事业部';
UPDATE departments SET name = '装配第一车间'       WHERE code = 'WS_ZHUANG' AND name <> '装配第一车间';
UPDATE departments SET name = '轨道装配车间'       WHERE code = 'WS_DLGD'   AND name <> '轨道装配车间';

-- ---------------- §1 岗位：按 (岗位名称 × 部门) 建档，缺则新建（code 取实际最大 ZW 序号），有则复用 ----------------
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

-- 复用的已有岗位若未设职级，按名录口径补上
UPDATE positions p
SET level = s.pos_level
FROM (SELECT DISTINCT pos_name, pos_level, dept_code FROM hr_roster) s
JOIN departments d ON d.code = s.dept_code
WHERE p.department_id = d.id AND p.name = s.pos_name AND p.level IS NULL;

-- 同步 ZW 序列（新建岗位后）
UPDATE master_code_sequences
SET last_seq = GREATEST(last_seq,
    (SELECT COALESCE(MAX(substring(code FROM 3)::int), 0) FROM positions WHERE code ~ '^ZW[0-9]+$'))
WHERE prefix = 'ZW';

-- ---------------- §2 员工主档 upsert（幂等键 = code） ----------------
INSERT INTO employees (code, full_name, gender, political_status, birth_date, id_type,
                       department_id, position_id, hire_date, status, employment_type,
                       huji_address, residence_address, legacy_category)
SELECT s.emp_code, s.full_name,
       NULLIF(s.gender, ''), NULLIF(s.political_status, ''), NULLIF(s.birth_date, '')::date,
       CASE WHEN NULLIF(s.id_card, '') IS NOT NULL THEN '身份证' ELSE '其他' END,
       d.id, p.id, s.hire_date::date, 'active', 'regular',
       NULLIF(s.huji, ''), NULLIF(s.residence, ''), 'HR正式名录2026-08'
FROM hr_roster s
JOIN departments d ON d.code = s.dept_code
LEFT JOIN positions p ON p.department_id = d.id AND p.name = s.pos_name AND p.is_deleted = false
ON CONFLICT (code) DO UPDATE SET
    full_name        = EXCLUDED.full_name,
    gender           = EXCLUDED.gender,
    political_status = EXCLUDED.political_status,
    birth_date       = EXCLUDED.birth_date,
    id_type          = EXCLUDED.id_type,
    department_id    = EXCLUDED.department_id,
    position_id      = EXCLUDED.position_id,
    hire_date        = EXCLUDED.hire_date,
    status           = EXCLUDED.status,
    employment_type  = EXCLUDED.employment_type,
    huji_address     = EXCLUDED.huji_address,
    residence_address = EXCLUDED.residence_address,
    legacy_category  = EXCLUDED.legacy_category;

-- 同步 UT 序列（含历史最大号，软删行也算，防重用）
UPDATE master_code_sequences
SET last_seq = GREATEST(last_seq,
    (SELECT COALESCE(MAX(substring(code FROM 3)::int), 0) FROM employees WHERE code ~ '^UT[0-9]+$'))
WHERE prefix = 'UT';

-- ---------------- §3 敏感信息：身份证/手机（pgcrypto + HMAC，与服务端同口径） ----------------
-- 名册内身份证/手机均唯一（构建脚本已查重）；仍保留 rn 防御：同证号只给最小工号挂哈希。
INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_last4, id_card_hash, phone_enc, phone_hash)
SELECT e.id,
       :'pgp_ver' || ':' || encode(pgp_sym_encrypt(COALESCE(NULLIF(BTRIM(s.id_card), ''), ''), :'pgp_key'), 'base64'),
       CASE WHEN NULLIF(BTRIM(s.id_card), '') IS NOT NULL THEN right(BTRIM(s.id_card), 4) END,
       CASE WHEN s.rn = 1 AND NULLIF(BTRIM(s.id_card), '') IS NOT NULL
            THEN encode(hmac(BTRIM(s.id_card), :'hmac_key', 'sha256'), 'hex') END,
       :'pgp_ver' || ':' || encode(pgp_sym_encrypt(COALESCE(NULLIF(BTRIM(s.phone), ''), ''), :'pgp_key'), 'base64'),
       CASE WHEN NULLIF(BTRIM(s.phone), '') IS NOT NULL
            THEN encode(hmac(BTRIM(s.phone), :'hmac_key', 'sha256'), 'hex') END
FROM (SELECT r.*,
             ROW_NUMBER() OVER (PARTITION BY NULLIF(BTRIM(r.id_card), '') ORDER BY r.emp_code) AS rn
      FROM hr_roster r) s
JOIN employees e ON e.code = s.emp_code
ON CONFLICT (employee_id) DO UPDATE
    SET id_card_enc   = EXCLUDED.id_card_enc,
        id_card_last4 = EXCLUDED.id_card_last4,
        id_card_hash  = EXCLUDED.id_card_hash,
        phone_enc     = EXCLUDED.phone_enc,
        phone_hash    = EXCLUDED.phone_hash;

-- ---------------- §4 部门负责人（高层兼职 + 部门经理；构建脚本已定，HR 可在部门页再核验） ----------------
UPDATE departments d
SET manager_id = e.id
FROM hr_mgr m
JOIN employees e ON e.code = m.emp_code
WHERE d.code = m.dept_code
  AND d.manager_id IS DISTINCT FROM e.id;

-- ---------------- §5 任职轨迹：onboard（名册为权威入职来源） ----------------
INSERT INTO employment_history (employee_id, event_type, to_dept_id, to_position_id, event_date, remark)
SELECT e.id, 'onboard', e.department_id, e.position_id, e.hire_date,
       'HR正式名录导入：入职时间以《中山市优腾电器职工信息表》为准'
FROM employees e
JOIN hr_roster s ON s.emp_code = e.code
WHERE NOT EXISTS (
    SELECT 1 FROM employment_history h
    WHERE h.employee_id = e.id AND h.event_type = 'onboard' AND h.event_date = e.hire_date);

-- ---------------- §6 departments.headcount 冗余重算（直属部门、在职、未删） ----------------
UPDATE departments d SET headcount = 0 WHERE headcount <> 0;
UPDATE departments d
SET headcount = sub.cnt
FROM (SELECT department_id, count(*) AS cnt
      FROM employees
      WHERE is_deleted = false AND status <> 'resigned'
      GROUP BY department_id) sub
WHERE d.id = sub.department_id;

COMMIT;

-- ---------------- 校验 ----------------
SELECT '✔ 名册 staging: ' || count(*) FROM hr_roster
UNION ALL SELECT 'employees 总数: ' || count(*) FROM employees WHERE is_deleted = false
UNION ALL SELECT '本迁移员工: ' || count(*) FROM employees WHERE legacy_category = 'HR正式名录2026-08'
UNION ALL SELECT 'active: ' || count(*) FROM employees WHERE legacy_category = 'HR正式名录2026-08' AND status = 'active'
UNION ALL SELECT '有岗位: ' || count(*) FROM employees WHERE legacy_category = 'HR正式名录2026-08' AND position_id IS NOT NULL
UNION ALL SELECT '敏感信息行: ' || count(*) FROM employee_sensitive s JOIN employees e ON e.id = s.employee_id WHERE e.legacy_category = 'HR正式名录2026-08'
UNION ALL SELECT '身份证哈希: ' || count(*) FROM employee_sensitive s JOIN employees e ON e.id = s.employee_id WHERE e.legacy_category = 'HR正式名录2026-08' AND s.id_card_hash IS NOT NULL
UNION ALL SELECT 'onboard 轨迹: ' || count(*) FROM employment_history h JOIN employees e ON e.id = h.employee_id WHERE e.legacy_category = 'HR正式名录2026-08' AND h.event_type = 'onboard'
UNION ALL SELECT '已设负责人部门: ' || count(*) FROM departments WHERE manager_id IS NOT NULL
UNION ALL SELECT '名册缺失（应 0）: ' || count(*) FROM hr_roster s WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.code = s.emp_code);

-- 部门人数分布（与名录口径对照）
SELECT d.code, d.name, d.headcount,
       (SELECT count(*) FROM employees e WHERE e.department_id = d.id AND e.is_deleted = false) AS actual
FROM departments d
WHERE d.id IN (SELECT DISTINCT department_id FROM employees WHERE is_deleted = false)
ORDER BY d.path;

-- 负责人一览
SELECT d.code, d.name AS dept, e.code AS mgr_code, e.full_name AS manager
FROM departments d JOIN employees e ON e.id = d.manager_id
ORDER BY d.path;

-- 抽查：高层 + 动态工龄（当前日期口径，每天都变，不落库）
SELECT e.code, e.full_name, d.name AS dept, p.name AS pos, p.level, e.hire_date,
       EXTRACT(YEAR FROM age(current_date, e.hire_date))::int || ' 年 ' ||
       EXTRACT(MONTH FROM age(current_date, e.hire_date))::int || ' 个月' AS 工龄_动态
FROM employees e
JOIN departments d ON d.id = e.department_id
LEFT JOIN positions p ON p.id = e.position_id
WHERE e.code IN ('UT0002','UT0009','UT0012','UT0011','UT0142')
ORDER BY e.code;
