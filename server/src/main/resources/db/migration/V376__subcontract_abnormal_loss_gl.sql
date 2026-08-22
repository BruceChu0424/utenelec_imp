-- V376: physical excess subcontract material loss is an expense and an
-- inventory-asset reduction. Supplier recovery remains a separate receivable
-- and income projection; normal contractual loss stays in qualified output cost.

INSERT INTO payment_styles(
    id,code,name,category,level,sort_order,path,is_receipt,is_payment,status,auto_created)
VALUES(
    '37600000-0000-4000-8100-000000000001','SYS-SUB-ABNORMAL-LOSS','委外超耗异常损失',
    'EXPENSE',0,930,'/SYS-SUB-ABNORMAL-LOSS/',FALSE,FALSE,'使用',TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO system_posting_style_roles(role_key,style_id,required_category,description)
VALUES(
    'SUBCONTRACT_ABNORMAL_LOSS','37600000-0000-4000-8100-000000000001','EXPENSE',
    '超过合同允许损耗的委外材料账面损失；不得与供应商赔偿或应付抵销净额记账')
ON CONFLICT(role_key) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM system_posting_style_roles role
        JOIN payment_styles style ON style.id=role.style_id
        WHERE role.role_key='SUBCONTRACT_ABNORMAL_LOSS'
          AND role.style_id='37600000-0000-4000-8100-000000000001'::UUID
          AND role.required_category='EXPENSE' AND style.category='EXPENSE'
          AND style.status='使用' AND COALESCE(style.is_deleted,FALSE)=FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='subcontract abnormal loss posting role is missing or mapped to an unreviewed UUID';
    END IF;
END $$;
