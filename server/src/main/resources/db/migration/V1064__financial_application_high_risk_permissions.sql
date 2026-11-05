-- These existing approval/execution actions must follow the same high-risk
-- permission assignment protection as every other financial action. This only
-- corrects catalog metadata: no user, department, role or surface grant changes.
UPDATE permissions SET high_risk=TRUE
 WHERE code IN ('application:receive','finance_application:review','finance_application:execute',
                'finance_application:confirm','finance_application:reverse')
   AND NOT high_risk;
