-- Reviewed local bootstrap only. Run inside the coordinator's transaction,
-- after its empty-candidate guard and before all business/master imports.
-- Required psql vars: legacy_key_file. Required files in the psql container:
-- /tmp/hr_rehearsal.csv and /tmp/hr_managers.csv. Never run this on a live DB.
\i :legacy_key_file
SELECT pg_advisory_xact_lock(1431586126, 282);
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

CREATE TEMP TABLE hr_rehearsal (
 emp_code text, seq text, legacy_id int, full_name text, gender text, political_status text,
 birth_date text, hire_date text, dept_code text, pos_name text, pos_level text, id_card text,
 phone text, huji text, residence text, note text, confirmed_at text, base_salary text,
 allowance_standard text, status text, office_phone text, email text, education text,
 source_kind text, hire_date_verified boolean);
\copy hr_rehearsal FROM '/tmp/hr_rehearsal.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE hr_rehearsal_managers (dept_code text, emp_code text);
\copy hr_rehearsal_managers FROM '/tmp/hr_managers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE hr_protected_admin AS
SELECT u.id, to_jsonb(u) AS original FROM users u
JOIN employees e ON e.id = u.employee_id
WHERE u.login_account = '17665410007' AND e.code = 'ADMIN';

DO $$
BEGIN
 IF (SELECT count(*) FROM hr_protected_admin) <> 1 OR (SELECT count(*) FROM users) <> 1 THEN
   RAISE EXCEPTION 'HR bootstrap requires exactly the preserved super-administrator account';
 END IF;
 IF EXISTS (SELECT 1 FROM employees WHERE code <> 'ADMIN' AND COALESCE(legacy_category,'') NOT LIKE 'HR重建彩排:%') THEN
   RAISE EXCEPTION 'HR bootstrap requires a fresh candidate or its own repeat run';
 END IF;
 IF EXISTS (SELECT 1 FROM hr_rehearsal s JOIN employees e ON e.code=s.emp_code
            WHERE e.full_name <> s.full_name OR e.legacy_id IS DISTINCT FROM s.legacy_id) THEN
   RAISE EXCEPTION 'HR repeat run employee identity differs';
 END IF;
 IF (SELECT count(*) FROM hr_rehearsal WHERE full_name='朱德洪' AND status='active' AND source_kind='chairman') <> 1
    OR EXISTS (SELECT 1 FROM hr_rehearsal WHERE source_kind NOT IN ('excel','chairman') AND status <> 'resigned') THEN
   RAISE EXCEPTION 'HR active population must equal Excel plus the chairman';
 END IF;
 IF EXISTS (SELECT 1 FROM hr_rehearsal s WHERE NOT EXISTS (SELECT 1 FROM departments d WHERE d.code=s.dept_code)) THEN
   RAISE EXCEPTION 'HR department mapping is incomplete';
 END IF;
 IF EXISTS (SELECT 1 FROM hr_rehearsal s WHERE s.emp_code !~ '^UT[0-9]{4,}$' OR s.hire_date IS NULL) THEN
   RAISE EXCEPTION 'HR code or required date missing';
 END IF;
 IF (SELECT min(substring(emp_code FROM 3)::int) FROM hr_rehearsal) <> 1
    OR (SELECT max(substring(emp_code FROM 3)::int) FROM hr_rehearsal) <> (SELECT count(*) FROM hr_rehearsal)
    OR (SELECT count(DISTINCT emp_code) FROM hr_rehearsal) <> (SELECT count(*) FROM hr_rehearsal) THEN
   RAISE EXCEPTION 'HR employee codes must be continuous from UT0001';
 END IF;
END $$;

-- Stable department codes preserve business mappings; names follow Excel.
UPDATE departments SET name = changes.name
FROM (VALUES ('FIN_CENTER','财税与行政管理中心'),('DEPT_FIN','财务部'),
 ('DEPT_SALES','综合营销事业部'),('WS_ZHUANG','装配第一车间'),('WS_DLGD','轨道装配车间'),
 ('WS_WJTZ','五金铜铸车间'),('SUB_PLAN','PMC运营计划部'),('SUB_PURCHASE','PMC运营采购部'),
 ('SUB_WH','PMC运营仓储部')) changes(code,name)
WHERE departments.code=changes.code AND departments.name IS DISTINCT FROM changes.name;

WITH need AS (
 SELECT DISTINCT s.pos_name,s.pos_level,d.id AS department_id,d.code AS dept_code
 FROM hr_rehearsal s JOIN departments d ON d.code=s.dept_code
 WHERE NOT EXISTS (SELECT 1 FROM positions p WHERE p.department_id=d.id AND p.name=s.pos_name AND NOT p.is_deleted)
), numbered AS (
 SELECT need.*, 'ZW'||lpad((actual.m+row_number() OVER(ORDER BY dept_code,pos_name))::text,4,'0') AS code
 FROM need CROSS JOIN (SELECT COALESCE(max(substring(code FROM 3)::int),0) AS m FROM positions WHERE code ~ '^ZW[0-9]+$') actual
)
INSERT INTO positions(code,name,level,department_id,sort_order)
SELECT code,pos_name,pos_level,department_id,100 FROM numbered;

INSERT INTO employees(code,legacy_id,full_name,gender,id_type,department_id,position_id,hire_date,
 confirmed_at,status,employment_type,birth_month_day,legacy_category)
SELECT s.emp_code,s.legacy_id,s.full_name,NULLIF(s.gender,''),
 CASE WHEN NULLIF(s.id_card,'') IS NULL THEN '其他' ELSE '身份证' END,
 d.id,p.id,s.hire_date::date,
 CASE WHEN s.source_kind='excel' THEN COALESCE(NULLIF(s.confirmed_at,'')::date,s.hire_date::date) END,
 s.status,'regular',CASE WHEN NULLIF(s.birth_date,'') IS NOT NULL THEN to_char(s.birth_date::date,'MM-DD') END,
 'HR重建彩排:'||s.source_kind
FROM hr_rehearsal s JOIN departments d ON d.code=s.dept_code
JOIN positions p ON p.department_id=d.id AND p.name=s.pos_name AND NOT p.is_deleted
ON CONFLICT(code) DO UPDATE SET
 full_name=EXCLUDED.full_name,gender=EXCLUDED.gender,id_type=EXCLUDED.id_type,
 department_id=EXCLUDED.department_id,position_id=EXCLUDED.position_id,hire_date=EXCLUDED.hire_date,
 confirmed_at=EXCLUDED.confirmed_at,status=EXCLUDED.status,birth_month_day=EXCLUDED.birth_month_day,
 legacy_category=EXCLUDED.legacy_category;

-- Encrypt all PII directly; no temporary plaintext in employees and no JVM
-- backfill dependency. Historical duplicate identities keep ciphertext but
-- one canonical row owns the global unique identity hash.
CREATE TEMP TABLE hr_rehearsal_sensitive AS
SELECT s.*,e.id AS employee_id,
 row_number() OVER(PARTITION BY NULLIF(s.id_card,'') ORDER BY s.emp_code) AS identity_rank
FROM hr_rehearsal s JOIN employees e ON e.code=s.emp_code;
INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_last4,id_card_hash,id_card_check,
 phone_enc,phone_hash,huji_address_enc,residence_address_enc,email_enc,birth_date_enc,
 political_status_enc,office_phone_enc)
SELECT employee_id,
 CASE WHEN NULLIF(id_card,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(id_card,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(id_card,'') IS NOT NULL THEN right(id_card,4) END,
 CASE WHEN NULLIF(id_card,'') IS NOT NULL AND identity_rank=1 THEN encode(hmac(id_card,:'hmac_key','sha256'),'hex') END,
 CASE WHEN NULLIF(id_card,'') IS NOT NULL THEN 'unchecked' END,
 CASE WHEN NULLIF(phone,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(phone,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(phone,'') IS NOT NULL THEN encode(hmac(phone,:'hmac_key','sha256'),'hex') END,
 CASE WHEN NULLIF(huji,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(huji,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(residence,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(residence,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(email,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(email,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(birth_date,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(birth_date,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(political_status,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(political_status,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(office_phone,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(office_phone,:'pgp_key'),'base64') END
FROM hr_rehearsal_sensitive
ON CONFLICT(employee_id) DO UPDATE SET
 id_card_enc=EXCLUDED.id_card_enc,id_card_last4=EXCLUDED.id_card_last4,id_card_hash=EXCLUDED.id_card_hash,
 id_card_check=EXCLUDED.id_card_check,phone_enc=EXCLUDED.phone_enc,phone_hash=EXCLUDED.phone_hash,
 huji_address_enc=EXCLUDED.huji_address_enc,residence_address_enc=EXCLUDED.residence_address_enc,
 email_enc=EXCLUDED.email_enc,birth_date_enc=EXCLUDED.birth_date_enc,
 political_status_enc=EXCLUDED.political_status_enc,office_phone_enc=EXCLUDED.office_phone_enc;

INSERT INTO employee_compensation(employee_id,base_salary_enc,allowance_standard_enc)
SELECT employee_id,
 CASE WHEN NULLIF(base_salary,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(base_salary,:'pgp_key'),'base64') END,
 CASE WHEN NULLIF(allowance_standard,'') IS NOT NULL THEN :'pgp_ver'||':'||encode(pgp_sym_encrypt(allowance_standard,:'pgp_key'),'base64') END
FROM hr_rehearsal_sensitive WHERE NULLIF(base_salary,'') IS NOT NULL OR NULLIF(allowance_standard,'') IS NOT NULL
ON CONFLICT(employee_id) DO UPDATE SET base_salary_enc=EXCLUDED.base_salary_enc,allowance_standard_enc=EXCLUDED.allowance_standard_enc;

INSERT INTO employee_education(employee_id,degree)
SELECT s.employee_id,s.education FROM hr_rehearsal_sensitive s WHERE NULLIF(s.education,'') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM employee_education x WHERE x.employee_id=s.employee_id AND x.degree=s.education);

-- Source B_Worker has no verifiable event timeline. Do not fabricate resign
-- dates or onboard events from its current status or default hire_date.
INSERT INTO employment_history(employee_id,event_type,to_dept_id,to_position_id,event_date,remark)
SELECT e.id,'onboard',e.department_id,e.position_id,e.hire_date,'HR重建彩排：入职日期来源于公司职工信息表'
FROM employees e JOIN hr_rehearsal s ON s.emp_code=e.code WHERE s.source_kind='excel'
AND NOT EXISTS (SELECT 1 FROM employment_history h WHERE h.employee_id=e.id AND h.event_type='onboard' AND h.event_date=e.hire_date);

UPDATE departments d SET manager_id=e.id FROM hr_rehearsal_managers m JOIN employees e ON e.code=m.emp_code WHERE d.code=m.dept_code;
UPDATE departments d SET headcount=(SELECT count(*) FROM employees e WHERE e.department_id=d.id AND NOT e.is_deleted AND e.status<>'resigned');
UPDATE positions p SET is_deleted=true,deleted_at=now()
WHERE NOT p.is_deleted AND (p.code ~ '^(LEAD_[123]|GRP_[123])(_[0-9]+)?$' OR p.code ~ '^MGT_(HEAD|DEPUTY|SPECIALIST)(_[0-9]+)?$')
AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.position_id=p.id);
UPDATE master_code_sequences SET last_seq=(SELECT max(substring(emp_code FROM 3)::int) FROM hr_rehearsal) WHERE prefix='UT';
UPDATE master_code_sequences SET last_seq=(SELECT COALESCE(max(substring(code FROM 3)::int),0) FROM positions WHERE code ~ '^ZW[0-9]+$') WHERE prefix='ZW';

-- Source-to-target decryption round trip: compare every imported encrypted
-- value, report counts only. A wrong field mapping or wrong key aborts the
-- enclosing bootstrap transaction without disclosing any plaintext.
CREATE TEMP TABLE hr_rehearsal_field_verification AS
SELECT fields.field_name,count(*) AS compared_rows,
 count(*) FILTER (WHERE fields.expected IS DISTINCT FROM
   CASE WHEN fields.actual_enc IS NOT NULL THEN pgp_sym_decrypt(decode(split_part(fields.actual_enc,':',2),'base64'),:'pgp_key') END) AS mismatch_count
FROM hr_rehearsal_sensitive s
JOIN employee_sensitive target ON target.employee_id=s.employee_id
LEFT JOIN employee_compensation compensation ON compensation.employee_id=s.employee_id
CROSS JOIN LATERAL (VALUES
 ('id_card',NULLIF(s.id_card,''),target.id_card_enc),
 ('phone',NULLIF(s.phone,''),target.phone_enc),
 ('birth_date',NULLIF(s.birth_date,''),target.birth_date_enc),
 ('political_status',NULLIF(s.political_status,''),target.political_status_enc),
 ('huji',NULLIF(s.huji,''),target.huji_address_enc),
 ('residence',NULLIF(s.residence,''),target.residence_address_enc),
 ('office_phone',NULLIF(s.office_phone,''),target.office_phone_enc),
 ('email',NULLIF(s.email,''),target.email_enc),
 ('base_salary',NULLIF(s.base_salary,''),compensation.base_salary_enc),
 ('allowance_standard',NULLIF(s.allowance_standard,''),compensation.allowance_standard_enc)
) fields(field_name,expected,actual_enc)
GROUP BY fields.field_name;

DO $$
BEGIN
 IF EXISTS (SELECT 1 FROM hr_protected_admin original LEFT JOIN users u ON u.id=original.id WHERE to_jsonb(u) IS DISTINCT FROM original.original) THEN
   RAISE EXCEPTION 'Protected administrator account changed during HR bootstrap';
 END IF;
 IF (SELECT count(*) FROM hr_rehearsal) <> (SELECT count(*) FROM employees WHERE code<>'ADMIN') THEN
   RAISE EXCEPTION 'HR output count differs from staged population';
 END IF;
 IF EXISTS (SELECT 1 FROM hr_rehearsal s JOIN employees e ON e.code=s.emp_code WHERE e.status<>s.status OR e.legacy_id IS DISTINCT FROM s.legacy_id) THEN
   RAISE EXCEPTION 'HR population status/legacy mapping verification failed';
 END IF;
 IF EXISTS (SELECT 1 FROM hr_rehearsal_field_verification WHERE mismatch_count<>0) THEN
   RAISE EXCEPTION 'HR encrypted source-to-target round-trip comparison failed';
 END IF;
END $$;
SELECT status,count(*) AS employee_count FROM employees GROUP BY status ORDER BY status;
SELECT * FROM hr_rehearsal_field_verification ORDER BY field_name;
