-- Forward-only stable role. Existing AP commercial credits and inventory cost facts are never rewritten.
INSERT INTO system_posting_style_roles(role_key,required_category,description)
VALUES('PROCUREMENT_RETURN_VARIANCE','EXPENSE','采购与委外退货商业贷项和库存实际成本差额，正数损失负数收益');
