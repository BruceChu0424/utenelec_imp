-- V375: fail closed if pre-existing role rows prevented V373 from installing
-- the exact reviewed UUID mappings.

DO $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM system_posting_style_roles role
        JOIN payment_styles style ON style.id=role.style_id
        WHERE role.role_key='SUPPLIER_CLAIM_RECEIVABLE'
          AND role.style_id='37300000-0000-4000-8100-000000000001'::UUID
          AND role.required_category='ACCOUNT' AND style.category='ACCOUNT'
          AND style.status='使用' AND COALESCE(style.is_deleted,FALSE)=FALSE)
       OR NOT EXISTS(
        SELECT 1 FROM system_posting_style_roles role
        JOIN payment_styles style ON style.id=role.style_id
        WHERE role.role_key='SUBCONTRACT_LOSS_RECOVERY'
          AND role.style_id='37300000-0000-4000-8100-000000000002'::UUID
          AND role.required_category='INCOME' AND style.category='INCOME'
          AND style.status='使用' AND COALESCE(style.is_deleted,FALSE)=FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='supplier claim system posting roles are missing or mapped to unreviewed UUIDs';
    END IF;
END $$;
