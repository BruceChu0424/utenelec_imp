-- Permission names describe current user actions. Authority IDs and reverse codes remain stable.
-- Quotation decisions and asset reversal are split without losing grants, denials or saved snapshots.
LOCK TABLE permissions, department_permissions, user_permission_overrides,
    manager_permission_delegations, permission_templates, users, authorization_state
    IN SHARE ROW EXCLUSIVE MODE;

CREATE TEMP TABLE v896_authorization_before ON COMMIT DROP AS
SELECT account.id, account.auth_version, account.permission_delegation_generation, state.epoch
FROM users account CROSS JOIN authorization_state state WHERE state.singleton_id=1;

-- Copy changes alone must never revoke a manager's existing delegation. All authority fields,
-- including future fields, still invalidate by default (V875's explicit exclusion model).
CREATE OR REPLACE FUNCTION fn_bump_permission_catalog_update_epoch()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM old_permission_rows old_row
        FULL JOIN new_permission_rows new_row ON new_row.id=old_row.id
        WHERE (to_jsonb(old_row)-ARRAY['name','description','module','category','sort_order','updated_at','updated_by'])
            IS DISTINCT FROM
              (to_jsonb(new_row)-ARRAY['name','description','module','category','sort_order','updated_at','updated_by'])
    ) THEN
        UPDATE authorization_state SET epoch=epoch+1,updated_at=CURRENT_TIMESTAMP WHERE singleton_id=1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Explicit names and explanations are appended below; historical migrations remain immutable.

CREATE TEMP TABLE v896_action_split(source_code,target_code,name,action_type,description,offset_order)
ON COMMIT DROP AS VALUES
    ('sales_quote_finance:confirm','sales_quote_finance:reject','退回销售报价','APPROVE','将待核价的报价退回销售修改；不能修改核价或确认报价。',1),
    ('sales_quote_finance:confirm','sales_quote_finance:reverse','重新核价销售报价','EXECUTE','将已确认的报价重新打开核价；不能确认报价或退回销售。',2),
    ('finance_asset:post','finance_asset:reverse','撤销资产和待摊计提入账','EXECUTE','发起撤销固定资产折旧或长期待摊摊销，并登记已通过审核的撤销批次；审核须另行授权，保留原入账及反向记录，仍受会计期间和后续账务限制。',1);

INSERT INTO permissions(code,name,module,category,action_type,description,sort_order,
    grant_policy,baseline,baseline_pinned,high_risk,sensitivity)
SELECT target.target_code,target.name,source.module,source.category,target.action_type,target.description,
       source.sort_order+target.offset_order,source.grant_policy,source.baseline,
       source.baseline_pinned,source.high_risk,source.sensitivity
FROM permissions source JOIN v896_action_split target ON target.source_code=source.code;

UPDATE permissions SET name='核价并确认销售报价',
    description='修改报价的财务核价并确认报价；退回销售和重新核价分别授权。'
WHERE code='sales_quote_finance:confirm';

CREATE TEMP TABLE v896_quote_action_split ON COMMIT DROP AS
SELECT source.id AS source_id,target.id AS target_id,target.code AS target_code,source.code AS source_code
FROM v896_action_split split JOIN permissions source ON source.code=split.source_code
JOIN permissions target ON target.code=split.target_code;

INSERT INTO department_permissions(department_id,permission_id,created_at,created_by)
SELECT allocation.department_id,split.target_id,allocation.created_at,allocation.created_by
FROM department_permissions allocation JOIN v896_quote_action_split split ON split.source_id=allocation.permission_id;

-- Preserve central revokes and neutral tombstones as well as grants; a split must not revive a denial.
INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source,source_actor_user_id,row_version,active)
SELECT decision.user_id,split.target_id,decision.effect,decision.authority_source,
       decision.source_actor_user_id,decision.row_version,decision.active
FROM user_permission_overrides decision JOIN v896_quote_action_split split ON split.source_id=decision.permission_id;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT mapping.surface_id,split.target_id
FROM permission_surface_permissions mapping JOIN v896_quote_action_split split ON split.source_id=mapping.permission_id;

-- The global epoch already invalidates every old token. Avoid recursively changing grantors'
-- versions while preserving delegation snapshots inside this locked, atomic migration.
ALTER TABLE manager_permission_delegations DISABLE TRIGGER trg_manager_permission_delegations_auth_version;
INSERT INTO manager_permission_delegations(
    user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,row_version,
    created_at,updated_at,created_by,updated_by,target_user_generation,target_employee_generation,
    target_department_generation,grantor_user_generation,grantor_employee_generation,
    grantor_auth_version,grantor_authorization_epoch,scope_source,scope_department_id,
    scope_generation,scope_assignment_id,scope_assignment_version)
SELECT delegation.user_id,split.target_id,delegation.department_id,delegation.enabled,
       delegation.surface_key,delegation.granted_by_user_id,delegation.row_version,
       delegation.created_at,delegation.updated_at,delegation.created_by,delegation.updated_by,
       delegation.target_user_generation,delegation.target_employee_generation,
       delegation.target_department_generation,delegation.grantor_user_generation,
       delegation.grantor_employee_generation,delegation.grantor_auth_version,
       delegation.grantor_authorization_epoch,delegation.scope_source,delegation.scope_department_id,
       delegation.scope_generation,delegation.scope_assignment_id,delegation.scope_assignment_version
FROM manager_permission_delegations delegation JOIN v896_quote_action_split split ON split.source_id=delegation.permission_id;

-- Rebase only snapshots current before this migration, including unrelated delegated capabilities.
-- Old epoch/version/user-generation mismatches stay stale; employee/department/scope generations stay untouched.
UPDATE manager_permission_delegations delegation
SET grantor_auth_version=grantor.auth_version,grantor_authorization_epoch=state.epoch,
    grantor_user_generation=CASE
        WHEN delegation.grantor_user_generation=previous.permission_delegation_generation
        THEN grantor.permission_delegation_generation ELSE delegation.grantor_user_generation END,
    target_user_generation=CASE
        WHEN delegation.target_user_generation=target_previous.permission_delegation_generation
        THEN target_account.permission_delegation_generation ELSE delegation.target_user_generation END,
    row_version=delegation.row_version+1
FROM v896_authorization_before previous JOIN users grantor ON grantor.id=previous.id
CROSS JOIN v896_authorization_before target_previous JOIN users target_account ON target_account.id=target_previous.id
CROSS JOIN authorization_state state
WHERE delegation.granted_by_user_id=previous.id
  AND delegation.user_id=target_previous.id
  AND delegation.grantor_auth_version=previous.auth_version
  AND delegation.grantor_authorization_epoch=previous.epoch AND state.singleton_id=1;
ALTER TABLE manager_permission_delegations ENABLE TRIGGER trg_manager_permission_delegations_auth_version;

-- Templates are snapshots, not runtime sources. Keep their previous meaning and invalidate previews.
UPDATE permission_templates template
SET permission_codes=(SELECT jsonb_agg(code ORDER BY code) FROM (
        SELECT jsonb_array_elements_text(template.permission_codes) AS code
        UNION SELECT target_code FROM v896_quote_action_split split WHERE template.permission_codes ? split.source_code
    ) expanded),row_version=template.row_version+1,updated_at=now()
WHERE NOT template.is_deleted AND EXISTS (
    SELECT 1 FROM v896_quote_action_split split WHERE template.permission_codes ? split.source_code
);

DO $$
BEGIN
    IF (SELECT count(*) FROM v896_quote_action_split)<>3 THEN
        RAISE EXCEPTION 'V896 requires the quotation decisions and asset reversal permissions';
    END IF;
END $$;
