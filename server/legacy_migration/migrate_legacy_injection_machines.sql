-- Fresh-candidate bootstrap only. Source CSV was read from B_WorkShop;
-- current WorkshopMachineService.createBatch uses prefix + integer (default
-- startNo=1, empty prefix), hence codes "1".."10" and not old IDs 60..69.
CREATE TEMP TABLE legacy_injection_machines (
 legacy_id int, source_name text, dept_code text, new_code text, new_name text, enabled boolean);
\copy legacy_injection_machines FROM '/tmp/legacy_injection_machines.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
DO $$
BEGIN
 IF (SELECT count(*) FROM users WHERE login_account='17665410007' AND NOT is_deleted) <> 1 THEN
  RAISE EXCEPTION 'Preserved super-administrator is required as machine creator';
 END IF;
 IF (SELECT count(*) FROM legacy_injection_machines) <> 10
    OR (SELECT count(DISTINCT new_code) FROM legacy_injection_machines) <> 10
    OR EXISTS (SELECT 1 FROM legacy_injection_machines WHERE new_code !~ '^[0-9]+$' OR new_code::int NOT BETWEEN 1 AND 10
                OR dept_code<>'WS_ZHUSU' OR enabled OR new_name<>source_name) THEN
  RAISE EXCEPTION 'Expected 10 source-backed disabled injection machines numbered 1 through 10';
 END IF;
 IF (SELECT count(*) FROM departments WHERE code='WS_ZHUSU' AND NOT is_deleted) <> 1 THEN
  RAISE EXCEPTION 'Injection workshop department mapping missing';
 END IF;
 IF EXISTS (SELECT 1 FROM legacy_injection_machines s JOIN departments d ON d.code=s.dept_code
             JOIN workshop_machines m ON m.workshop_department_id=d.id AND m.code=s.new_code AND NOT m.is_deleted
             WHERE m.name<>s.new_name OR m.remark IS DISTINCT FROM '老库B_WorkShop.ID='||s.legacy_id||'；历史机台名称待现场核验') THEN
  RAISE EXCEPTION 'Machine code is occupied by a different current machine';
 END IF;
END $$;
INSERT INTO workshop_machines(workshop_department_id,code,name,enabled,sort_order,remark,created_by)
SELECT d.id,s.new_code,s.new_name,false,s.new_code::int,
 '老库B_WorkShop.ID='||s.legacy_id||'；历史机台名称待现场核验',u.id
FROM legacy_injection_machines s JOIN departments d ON d.code=s.dept_code
JOIN users u ON u.login_account='17665410007' AND NOT u.is_deleted
WHERE NOT EXISTS (SELECT 1 FROM workshop_machines m WHERE m.workshop_department_id=d.id AND m.code=s.new_code AND NOT m.is_deleted);
-- model/tonnage remain NULL; no invented container or capacity records.
SELECT count(*) AS imported_disabled_machines FROM workshop_machines m
JOIN departments d ON d.id=m.workshop_department_id
WHERE d.code='WS_ZHUSU' AND NOT m.is_deleted AND NOT m.enabled
AND m.remark LIKE '老库B_WorkShop.ID=%；历史机台名称待现场核验';
