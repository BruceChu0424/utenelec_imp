-- Read-only release preflight. Grant through the existing administrator API/UI;
-- its account lifecycle, step-up authentication, grant policy and audit remain authoritative.
BEGIN READ ONLY;

SELECT u.id AS reviewer_user_id,e.code AS employee_code,e.full_name,
       u.login_account,u.status AS account_status,e.status AS employee_status,u.is_super_admin
FROM users u JOIN employees e ON e.id=u.employee_id
WHERE NOT u.is_deleted AND NOT e.is_deleted AND e.full_name='朱舜炜'
ORDER BY u.id;

SELECT p.code,p.name,p.module,p.category,p.grant_policy,p.explicit_grant_required
FROM permissions p
WHERE p.code LIKE 'sales_quote_manager:%' OR p.code LIKE 'sales_order_manager:%'
ORDER BY p.sort_order,p.code;

-- Only an unambiguous active ordinary account yields the narrow, additive grant request.
WITH candidates AS (
    SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id
    WHERE NOT u.is_deleted AND u.status='active' AND NOT u.is_super_admin
      AND NOT e.is_deleted AND e.status<>'resigned' AND e.full_name='朱舜炜'
)
SELECT format('GET /api/admin/users/%s/permission-overrides',id) AS read_current_overrides,
       ARRAY(SELECT code FROM permissions WHERE code LIKE 'sales_quote_manager:%'
           OR code LIKE 'sales_order_manager:%' ORDER BY code) AS intended_review_codes,
       'Merge these eight codes into the current grants and remove only their revokes; preserve all other overrides. Save through the existing audited UI/API with one-time step-up authentication. Do not grant the whole sales quote/order categories.' AS authorization
FROM candidates WHERE (SELECT count(*) FROM candidates)=1
    AND (SELECT count(*) FROM permissions WHERE code LIKE 'sales_quote_manager:%' OR code LIKE 'sales_order_manager:%')=8;

ROLLBACK;
