-- Read-only release preflight. Grant through the existing administrator API/UI;
-- its account lifecycle, step-up authentication, grant policy and audit remain authoritative.
BEGIN READ ONLY;

SELECT u.id AS reviewer_user_id,e.code AS employee_code,e.full_name,
       u.login_account,u.status AS account_status,e.status AS employee_status,u.is_super_admin
FROM users u JOIN employees e ON e.id=u.employee_id
WHERE NOT u.is_deleted AND NOT e.is_deleted AND e.full_name='朱舜炜'
ORDER BY u.id;

SELECT p.code,p.name,p.active,p.grant_policy,p.explicit_grant_required
FROM permissions p
WHERE p.module='综合营销部' AND p.category='订单审核'
ORDER BY p.sort_order,p.code;

-- Only an unambiguous active ordinary account yields the narrow, additive grant request.
WITH candidates AS (
    SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id
    WHERE NOT u.is_deleted AND u.status='active' AND NOT u.is_super_admin
      AND NOT e.is_deleted AND e.status<>'resigned' AND e.full_name='朱舜炜'
)
SELECT format('PUT /api/admin/users/%s/permission-overrides/grant-all',id) AS endpoint,
       jsonb_build_object('module','综合营销部','category','订单审核') AS request_body,
       'Use the existing super-administrator session and one-time step-up credential' AS authorization
FROM candidates WHERE (SELECT count(*) FROM candidates)=1
    AND (SELECT count(*) FROM permissions WHERE module='综合营销部' AND category='订单审核' AND active)=8;

ROLLBACK;
