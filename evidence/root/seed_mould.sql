\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('app.actor_id',(SELECT id::text FROM users WHERE login_account=:'bootstrap_login'),true) AS actor \gset
INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
SELECT seed.id,seed.code,seed.name,admin.id_type,admin.department_id,CURRENT_DATE,'active','regular'
FROM (VALUES
 ('73000000-0000-4000-8000-000000000001'::uuid,'FMWEBQA','Synthetic Mould Web'),
 ('73000000-0000-4000-8000-000000000002'::uuid,'FMWINQA','Synthetic Mould Windows')
) seed(id,code,name) CROSS JOIN employees admin WHERE admin.code='ADMIN';
INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
SELECT seed.id,seed.employee,seed.login,maker.password_hash,FALSE,FALSE,'active'
FROM (VALUES
 ('73000000-0000-4000-8000-000000000003'::uuid,'73000000-0000-4000-8000-000000000001'::uuid,'feedback-mould-qa'),
 ('73000000-0000-4000-8000-000000000004'::uuid,'73000000-0000-4000-8000-000000000002'::uuid,'feedback-mould-win-qa')
) seed(id,employee,login) CROSS JOIN users maker WHERE maker.id=:'maker_id'::uuid;
INSERT INTO user_permission_overrides(user_id,permission_id,effect)
SELECT account.id,permission.id,'grant' FROM users account CROSS JOIN permissions permission
WHERE account.login_account IN('feedback-mould-qa','feedback-mould-win-qa')
 AND permission.code IN('mould:view','mould:export');
INSERT INTO mould_categories(id,code,name)
VALUES('73000000-0000-4000-8000-000000000005','FEEDBACK-MOULD','Synthetic feedback moulds');
WITH sequence AS(SELECT coalesce(max(code_sequence),0) AS base FROM moulds)
INSERT INTO moulds(id,code,name,status,category_id,code_sequence,code_managed,tqty,manufacturer)
SELECT md5('feedback-mould-20261110/'||n)::uuid,'AU-'||lpad(n::text,5,'0'),
 'Synthetic Mould '||lpad(n::text,5,'0'),'使用','73000000-0000-4000-8000-000000000005',
 sequence.base+n,FALSE,(1627-n)+0.125,'Synthetic Factory'
FROM generate_series(1,1626) n CROSS JOIN sequence;
DO $$BEGIN
 IF (SELECT count(*) FROM moulds WHERE category_id='73000000-0000-4000-8000-000000000005')<>1626
   OR (SELECT count(*) FROM users WHERE login_account IN('feedback-mould-qa','feedback-mould-win-qa') AND NOT is_super_admin)<>2
 THEN RAISE EXCEPTION 'Synthetic mould fixture incomplete'; END IF;
END$$;
COMMIT;
SELECT count(*) AS synthetic_moulds,min(code),max(code),min(tqty),max(tqty)
FROM moulds WHERE category_id='73000000-0000-4000-8000-000000000005';
SELECT login_account,is_super_admin,status FROM users
WHERE login_account IN('feedback-mould-qa','feedback-mould-win-qa') ORDER BY login_account;
