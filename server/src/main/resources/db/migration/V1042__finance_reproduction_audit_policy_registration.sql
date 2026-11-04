-- V1001/V1002/V1004/V1007/V1023 已应用且字节不可变。财务复刻/精度批次在这些建表迁移里
-- 手写了 fn_audit() 触发器；按 V975 先例统一改走公共 fn_audit_track_table 前向登记：
-- 只按 OID 移除审计函数触发器，保留业务守卫与历史，之后由三清单契约
-- (AuditTriggerCoverageMigrationContractTest) 锁定。人工维护的申请工作流与财务单据
-- 按 FULL/data_change 整行审计。
SELECT public.fn_audit_track_table('business_applications', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('business_application_events', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('business_application_submissions', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('department_approval_policies', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_statement_profiles', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_statement_document_reviews', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_advances', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_advance_parts', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_advance_applications', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_advance_refunds', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_payable_statement_adjustments', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_payable_statement_adjustment_lines', 'FULL', 'data_change', false, NULL, true, NULL);

-- V1006/V1015 用动态循环登记的 COLUMN_SCOPED 策略在此按同一列清单显式复述一遍：
-- 本库行为与原登记保持等价（同一函数、同一类别、同一列清单、同一插入/删除开关），
-- 静态契约由此可直接核对「定位线索，不复制金额与业务原文」的既定口径。
SELECT public.fn_audit_track_table('finance_payroll_preparations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['application_id','batch_id','source_fingerprint','instruction_fingerprint','prepared_by','prepared_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_payroll_accruals', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','application_id','source_fingerprint','instruction_fingerprint','mode','voucher_id','wage_style_id','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_payroll_payment_attempts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','application_id','batch_id','source_fingerprint','instruction_fingerprint','account_id','payment_date','fee_style_id','payment_voucher_id','non_cash_voucher_id','receipt_kind','source_claim_only','account_flow_id','state','paid_at','paid_by','confirmed_at','confirmed_by','reversal_voucher_id','reversed_at','reversed_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_payroll_payment_actions', 'COLUMN_SCOPED', 'data_change', false, ARRAY['request_id','application_id','payment_request_id','action','actor_id','fingerprint','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_scopes', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','style_id','account_code','auxiliary_id','auxiliary_role','party_id_snapshot','accounting_currency_id','original_currency_id','natural_direction'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_reservations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','scope_id','owner_kind','owner_id','actor_id','as_of','mode','fingerprint','status','created_at','updated_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_source_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['reservation_id','entry_id','allocation_no'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_clearings', 'COLUMN_SCOPED', 'data_change', false, ARRAY['reservation_id','line_no','entry_id','allocation_no','source_entry_id','source_allocation_no'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_reversals', 'COLUMN_SCOPED', 'data_change', false, ARRAY['reservation_id','line_no','entry_id','allocation_no','original_entry_id','original_allocation_no'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_settlement_operations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['request_id','actor_id','fingerprint','operation','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_receipt_classification_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','receipt_line_id','revision','source_classification_id','currency_id','created_by','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_receipt_classification_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','category'], true, NULL);
SELECT public.fn_audit_track_table('finance_customer_offset_classification_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','offset_id','revision','source_classification_id','target_classification_id','source_kind','created_by','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_customer_offset_classification_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','source_category','target_category'], true, NULL);

-- 汇总登记后刷新审计元数据投影（V1006 引入的公共入口，V1024/V1034 同款收尾）。
SELECT fn_refresh_finance_audit_metadata_projection();
