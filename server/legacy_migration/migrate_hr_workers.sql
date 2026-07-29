-- =====================================================================
-- 人事老库迁移：B_Worker → employees + positions + employee_sensitive（试迁测试数据）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --hr-workers
-- 前提：V84 已应用（legacy_departments.department_id）；departments 已初始化；hr_workers.csv 已导出。
-- 设计（用户钦定思路）：
--   · 人事正式录入前，老库 B_Worker 72 人全量迁入做测试数据；以后再删除/重迁。
--   · 只动 stub（code 前缀 'LEGACY-W-'）：HR 正式录入的真员工（同 legacy_id）一律不覆盖。
--   · 老库 Status='使用'→active、其余（禁用）→resigned，legacy_category 标注「老库迁移/老数据中有用」。
--   · 部门：ParentID → SystemItem(ItemclassID=5) → legacy_departments.department_id → departments
--     （映射表集中在本文件 §1，HR review 改这里即可，重跑幂等）。
--   · 职位：老库 Post/Duty 全空，实际工种在 Emp_Style → 按 (工种, 映射部门) 建 positions（LEG-P-* 码）。
--   · PII：身份证/手机按服务端同口径 pgcrypto 加密 + HMAC 查重哈希（密钥经 /tmp/_uten_keys.sql
--     注入，migrate.sh 用后即时删除，不落库不明文）。
-- 幂等：全量 upsert（employees 按 legacy_id、positions 按 (code,department_id)、
--   sensitive 按 employee_id），重跑安全。
-- =====================================================================

-- 注入密钥变量（:pgp_key / :pgp_ver / :hmac_key），文件由 migrate.sh 生成、用后删除
\i /tmp/_uten_keys.sql

BEGIN;
SET session_replication_role = replica;

-- ---------------- staging（可选列全 text，NULLIF 处空串） ----------------
CREATE TEMP TABLE hr_stage (
    legacy_id int, full_name text, worker_number text, dept_legacy_id int,
    birth_date text, sex text, education text, emp_style text, work_date text,
    id_card text, mobile text, nat_place text, phone text, work_phone text,
    email text, address text, remark text, legacy_status text);
\copy hr_stage FROM '/tmp/hr_workers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- §1 老库部门 → 新库部门映射（HR review 集中改这里） ----------------
-- 老库 SystemItem(ItemclassID=5)：2129总经办 2130销售部 2131OEM部 2132行政部 2133工程部
--   2134品质部 2139安装部 2142注塑部 2146铜柱部 2147计划部 2148财务部 2527其它 2675仓库
--   2676离职人员 2680采购部
CREATE TEMP TABLE dept_map (legacy_id int PRIMARY KEY, new_code text);
INSERT INTO dept_map VALUES
    (2129, 'GM'),           -- 总经办 → 总经办
    (2130, 'DEPT_SALES'),   -- 销售部 → 综合营销部
    (2131, 'DEPT_SALES'),   -- OEM部 → 综合营销部（新库无 OEM 单列，归营销；0 人）
    (2132, 'DEPT_HR'),      -- 行政部 → 行政与人力资源部
    (2133, 'DEPT_ENG'),     -- 工程部 → 工程研发部
    (2134, 'DEPT_QA'),      -- 品质部 → 品质管理部
    (2139, 'DEPT_PROD'),    -- 安装部 → 生产部（22 人，安装/安装QC/安装主管；HR 可改 WS_ZHUANG 装配车间）
    (2142, 'WS_ZHUSU'),     -- 注塑部 → 注塑车间
    (2146, 'WS_WJTZ'),      -- 铜柱部 → 五金铜柱车间
    (2147, 'SUB_PLAN'),     -- 计划部 → 计划部
    (2148, 'DEPT_FIN'),     -- 财务部 → 财税部
    (2527, 'DEPT_HR'),      -- 其它 → 行政与人力资源部（0 人）
    (2675, 'SUB_WH'),       -- 仓库 → 仓储部
    (2676, 'DEPT_HR'),      -- 离职人员 → 行政与人力资源部（0 人，状态强制 resigned）
    (2680, 'SUB_PURCHASE'); -- 采购部 → 采购部（0 人）

-- 映射写回 legacy_departments（字典行不存在则补，name 以老库导出为准）
INSERT INTO legacy_departments (legacy_id, name, code, department_id)
SELECT m.legacy_id, '(老库部门 ' || m.legacy_id || ')', NULL,
       (SELECT id FROM departments d WHERE d.code = m.new_code)
FROM dept_map m
ON CONFLICT (legacy_id) DO UPDATE
    SET department_id = EXCLUDED.department_id;

-- ---------------- §2 职位：Emp_Style 工种 → positions（按 工种×映射部门 建档） ----------------
INSERT INTO positions (code, name, department_id, sort_order)
SELECT 'LEG-P-' || left(md5(BTRIM(s.emp_style) || '|' || s.dept_legacy_id::text), 8),
       BTRIM(s.emp_style),
       ld.department_id,
       900
FROM (SELECT DISTINCT BTRIM(emp_style) AS emp_style, dept_legacy_id FROM hr_stage
      WHERE NULLIF(BTRIM(emp_style), '') IS NOT NULL) s
JOIN legacy_departments ld ON ld.legacy_id = s.dept_legacy_id AND ld.department_id IS NOT NULL
ON CONFLICT (code, department_id) DO NOTHING;

-- ---------------- §3 员工主档：仅动 stub（LEGACY-W-*），HR 真员工不覆盖 ----------------
-- 3a. 已存在 stub → 全字段丰富
UPDATE employees e
SET full_name         = NULLIF(BTRIM(s.full_name), ''),
    gender            = CASE BTRIM(s.sex) WHEN '1' THEN 'male' WHEN '2' THEN 'female' ELSE NULL END,
    birth_date        = NULLIF(BTRIM(s.birth_date), '')::date,
    id_type           = CASE WHEN NULLIF(BTRIM(s.id_card), '') IS NOT NULL THEN '身份证' ELSE '其他' END,
    department_id     = COALESCE(ld.department_id, (SELECT id FROM departments WHERE code = 'DEPT_HR')),
    position_id       = (SELECT p.id FROM positions p
                         WHERE p.code = 'LEG-P-' || left(md5(BTRIM(s.emp_style) || '|' || s.dept_legacy_id::text), 8)
                           AND p.department_id = ld.department_id),
    hire_date         = COALESCE(NULLIF(BTRIM(s.work_date), '')::date, DATE '2000-01-01'),
    status            = CASE WHEN BTRIM(s.legacy_status) = '使用' THEN 'active' ELSE 'resigned' END,
    residence_address = NULLIF(BTRIM(s.address), ''),
    huji_address      = NULLIF(BTRIM(s.nat_place), ''),
    office_phone      = COALESCE(NULLIF(BTRIM(s.work_phone), ''), NULLIF(BTRIM(s.phone), '')),
    email             = NULLIF(BTRIM(s.email), ''),
    legacy_category   = '老库B_Worker迁移' ||
                        CASE WHEN BTRIM(s.legacy_status) = '使用' THEN '' ELSE '（老数据中有用·老库已禁用）' END
FROM hr_stage s
LEFT JOIN legacy_departments ld ON ld.legacy_id = s.dept_legacy_id
WHERE e.legacy_id = s.legacy_id
  AND e.code LIKE 'LEGACY-W-%';          -- 只动 stub，HR 真员工跳过

-- 3b. 老库有、employees 没有 → 新建 stub（正式录入后对不上的即「离职保留」人口）
INSERT INTO employees (legacy_id, code, full_name, gender, birth_date, id_type, department_id, position_id,
                       hire_date, status, employment_type, residence_address, huji_address,
                       office_phone, email, legacy_category)
SELECT s.legacy_id, 'LEGACY-W-' || s.legacy_id, NULLIF(BTRIM(s.full_name), ''),
       CASE BTRIM(s.sex) WHEN '1' THEN 'male' WHEN '2' THEN 'female' ELSE NULL END,
       NULLIF(BTRIM(s.birth_date), '')::date,
       CASE WHEN NULLIF(BTRIM(s.id_card), '') IS NOT NULL THEN '身份证' ELSE '其他' END,
       COALESCE(ld.department_id, (SELECT id FROM departments WHERE code = 'DEPT_HR')),
       (SELECT p.id FROM positions p
        WHERE p.code = 'LEG-P-' || left(md5(BTRIM(s.emp_style) || '|' || s.dept_legacy_id::text), 8)
          AND p.department_id = ld.department_id),
       COALESCE(NULLIF(BTRIM(s.work_date), '')::date, DATE '2000-01-01'),
       CASE WHEN BTRIM(s.legacy_status) = '使用' THEN 'active' ELSE 'resigned' END,
       'regular',
       NULLIF(BTRIM(s.address), ''), NULLIF(BTRIM(s.nat_place), ''),
       COALESCE(NULLIF(BTRIM(s.work_phone), ''), NULLIF(BTRIM(s.phone), '')),
       NULLIF(BTRIM(s.email), ''),
       '老库B_Worker迁移' ||
       CASE WHEN BTRIM(s.legacy_status) = '使用' THEN '' ELSE '（老数据中有用·老库已禁用）' END
FROM hr_stage s
LEFT JOIN legacy_departments ld ON ld.legacy_id = s.dept_legacy_id
WHERE s.legacy_id IS NOT NULL AND s.legacy_id <> 0
  AND NULLIF(BTRIM(s.full_name), '') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = s.legacy_id);

-- ---------------- §4 敏感信息：身份证/手机（pgcrypto + HMAC，与服务端同口径） ----------------
-- 仅 stub 员工；id_card_enc/phone_enc 非空约束 → 缺省存空串密文，hash 留 NULL（不参与查重）。
-- 老库存在同人重复建档（如 罗孝南 231/362 同身份证号）：id_card_hash 有唯一约束，
-- 同证号只给最小 legacy_id 那行挂哈希，其余留 NULL（查重语义保留给唯一档）。
INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_last4, id_card_hash, phone_enc, phone_hash)
SELECT e.id,
       :'pgp_ver' || ':' || encode(pgp_sym_encrypt(COALESCE(NULLIF(BTRIM(s.id_card), ''), ''), :'pgp_key'), 'base64'),
       CASE WHEN NULLIF(BTRIM(s.id_card), '') IS NOT NULL THEN right(BTRIM(s.id_card), 4) END,
       CASE WHEN s.rn = 1
            THEN encode(hmac(BTRIM(s.id_card), :'hmac_key', 'sha256'), 'hex') END,
       :'pgp_ver' || ':' || encode(pgp_sym_encrypt(COALESCE(NULLIF(BTRIM(s.mobile), ''), ''), :'pgp_key'), 'base64'),
       CASE WHEN NULLIF(BTRIM(s.mobile), '') IS NOT NULL
            THEN encode(hmac(BTRIM(s.mobile), :'hmac_key', 'sha256'), 'hex') END
FROM (SELECT hs.*,
             ROW_NUMBER() OVER (PARTITION BY NULLIF(BTRIM(hs.id_card), '') ORDER BY hs.legacy_id) AS rn
      FROM hr_stage hs) s
JOIN employees e ON e.legacy_id = s.legacy_id AND e.code LIKE 'LEGACY-W-%'
ON CONFLICT (employee_id) DO UPDATE
    SET id_card_enc   = EXCLUDED.id_card_enc,
        id_card_last4 = EXCLUDED.id_card_last4,
        id_card_hash  = EXCLUDED.id_card_hash,
        phone_enc     = EXCLUDED.phone_enc,
        phone_hash    = EXCLUDED.phone_hash;

COMMIT;

-- ---------------- 校验 ----------------
SELECT '✔ 老库 B_Worker 总数 ' || (SELECT count(*) FROM hr_stage) AS r
UNION ALL SELECT 'employees 有 legacy_id（含 HR 真员工） ' || (SELECT count(*) FROM employees WHERE legacy_id IS NOT NULL)
UNION ALL SELECT 'stub 员工（LEGACY-W-*） ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%')
UNION ALL SELECT 'stub 中 active（老库使用） ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%' AND status = 'active')
UNION ALL SELECT 'stub 中 resigned（老库禁用） ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%' AND status = 'resigned')
UNION ALL SELECT 'stub 有部门映射 ' || (SELECT count(DISTINCT e.id) FROM employees e JOIN legacy_departments ld ON ld.department_id = e.department_id WHERE e.code LIKE 'LEGACY-W-%')
UNION ALL SELECT 'stub 有职位 ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%' AND position_id IS NOT NULL)
UNION ALL SELECT 'stub 有敏感信息行 ' || (SELECT count(*) FROM employee_sensitive s JOIN employees e ON e.id = s.employee_id WHERE e.code LIKE 'LEGACY-W-%')
UNION ALL SELECT 'stub 有身份证哈希 ' || (SELECT count(*) FROM employee_sensitive s JOIN employees e ON e.id = s.employee_id WHERE e.code LIKE 'LEGACY-W-%' AND s.id_card_hash IS NOT NULL)
UNION ALL SELECT '老库部门映射已配 ' || (SELECT count(*) FROM legacy_departments WHERE department_id IS NOT NULL)
UNION ALL SELECT '新建 LEG-P 职位 ' || (SELECT count(*) FROM positions WHERE code LIKE 'LEG-P-%')
UNION ALL SELECT '老库有但 employees 缺失（应 0） ' || (
    SELECT count(*) FROM hr_stage s WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = s.legacy_id))
UNION ALL SELECT '老库同人重复身份证组数（仅首行挂哈希） ' || (
    SELECT count(*) FROM (SELECT NULLIF(BTRIM(id_card), '') AS c FROM hr_stage
                          WHERE NULLIF(BTRIM(id_card), '') IS NOT NULL
                          GROUP BY 1 HAVING count(*) > 1) t);
