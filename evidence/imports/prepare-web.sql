-- Run only against the new isolated synthetic acceptance database.
-- psql -v actor=<existing ordinary test user UUID> -f prepare-web.sql
-- The user's password/login is managed by the parent acceptance fixture.
BEGIN;
DO $$ BEGIN IF current_database() IN ('uten_imp','production') THEN
    RAISE EXCEPTION 'Use a named isolated acceptance database'; END IF; END $$;
INSERT INTO user_permission_overrides(user_id,permission_id,effect)
SELECT :'actor'::uuid,id,'grant' FROM permissions
WHERE code IN ('finance_report:view','finance:view:all','payment_style:edit','finance_post:execute',
              'goods:view','goods:cost:view','goods:cost:edit','goods:import')
ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant';
SELECT id,login_account,is_super_admin,status FROM users WHERE id=:'actor'::uuid;
COMMIT;
