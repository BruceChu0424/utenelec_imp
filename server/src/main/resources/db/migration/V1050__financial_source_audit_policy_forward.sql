-- Forward-only completion of the V999_x financial audit inventory.
-- Use the single public registrar: it replaces only audit-function triggers by OID,
-- preserving business guards, facts and already-written audit history.
-- Private source bodies, previews, monetary allocations and command results stay
-- in their owning financial readers; general audit keeps identities and decisions.

-- 科目原件只留导入身份、摘要与完成时间；预览和结果保持私有
SELECT public.fn_audit_track_table('finance_chart_imports','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','sha256','applied_at','created_at'],true,NULL);

-- 科目对应审计只留身份、分类、币别、版本及映射指纹
SELECT public.fn_audit_track_table('finance_chart_codes','COLUMN_SCOPED','data_change',false,ARRAY['code','native_style_id','source_import_id','source_kind','classification','currency_id','row_version','mapping_fingerprint','updated_at','updated_by'],true,NULL);

-- 手动科目命令只留请求、操作者与指纹，回执不复制到审计
SELECT public.fn_audit_track_table('finance_chart_manual_operations','COLUMN_SCOPED','data_change',false,ARRAY['request_id','actor_id','fingerprint','created_at'],true,NULL);

-- 财务代码与实际科目UUID对应保留关联和操作者
SELECT public.fn_audit_track_table('finance_chart_code_styles','COLUMN_SCOPED','data_change',false,ARRAY['code','style_id','created_at','created_by'],true,NULL);

-- 科目命令拥有的报表绑定只留代码、UUID和稳定行键
SELECT public.fn_audit_track_table('finance_chart_owned_bindings','COLUMN_SCOPED','data_change',false,ARRAY['code','style_id','line_key'],true,NULL);

-- 原账套批次保留状态与双人核对定位，原文件、预览、正文和结果不进入审计
SELECT public.fn_audit_track_table('finance_accounting_import_batches','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','sha256','status','row_version','submitted_by','submitted_at','approved_by','approved_at','created_at','kind','paired_import_id','reversed_at','reversed_by'],true,NULL);

-- 账套复核命令只留请求、批次、动作及指纹
SELECT public.fn_audit_track_table('finance_accounting_review_operations','COLUMN_SCOPED','data_change',false,ARRAY['request_id','actor_id','import_id','action','fingerprint','created_at'],true,NULL);

-- 原凭证证明只留来源摘要、性质及复核关系，不复制原凭证快照
SELECT public.fn_audit_track_table('finance_gl_voucher_evidence','COLUMN_SCOPED','data_change',false,ARRAY['voucher_id','import_batch_id','purpose','source_sha256','submitted_by','approved_by','approved_at','reversed_voucher_id'],true,NULL);

-- 分录辅助分摊只留身份、币别与行定位；金额、原科目名称和原始快照保持私有
SELECT public.fn_audit_track_table('finance_gl_entry_allocations','COLUMN_SCOPED','data_change',false,ARRAY['entry_id','allocation_no','account_code','auxiliary_id','currency_id','original_currency_id','auxiliary_role','party_id_snapshot','source_row','created_at','created_by'],true,NULL);

-- 辅助期初只留批次、身份、日期与复核摘要，不复制期初金额和源名称
SELECT public.fn_audit_track_table('finance_gl_auxiliary_opening_evidence','COLUMN_SCOPED','data_change',false,ARRAY['id','import_batch_id','account_code','auxiliary_id','currency_id','original_currency_id','effective_from','entry_id','auxiliary_role','party_id_snapshot','source_sha256','source_row','submitted_by','approved_by','approved_at'],true,NULL);

-- 期初基准只留起点、批次和确认摘要
SELECT public.fn_audit_track_table('finance_gl_opening_baselines','COLUMN_SCOPED','data_change',false,ARRAY['effective_from','import_batch_id','source_sha256','verified_by','verified_at'],true,NULL);

-- 完整期间核证保留版本、依据种类与确认摘要
SELECT public.fn_audit_track_table('finance_accounting_period_coverage','COLUMN_SCOPED','data_change',false,ARRAY['period','entries_revision','source_kind','import_batch_id','source_sha256','verified_by','verified_at'],true,NULL);

-- 总账分录变动自动维护的版本戳；保留现有计数与核证守卫，不重复制造人为审计事件
SELECT public.fn_audit_track_table('finance_gl_period_versions','NONE','data_change',false,NULL,true,NULL);

-- 辅助项目与科目辅助规则为人工维护的主档/身份对应，继续完整审计其决定
SELECT public.fn_audit_track_table('finance_auxiliary_parties','FULL','data_change',false,NULL,true,NULL);

-- 辅助项目与科目辅助规则为人工维护的主档/身份对应，继续完整审计其决定
SELECT public.fn_audit_track_table('finance_auxiliary_items','FULL','data_change',false,NULL,true,NULL);

-- 辅助项目与科目辅助规则为人工维护的主档/身份对应，继续完整审计其决定
SELECT public.fn_audit_track_table('finance_account_auxiliary_rules','FULL','data_change',false,NULL,true,NULL);

-- 辅助项目与科目辅助规则为人工维护的主档/身份对应，继续完整审计其决定
SELECT public.fn_audit_track_table('finance_account_auxiliary_bindings','FULL','data_change',false,NULL,true,NULL);

-- 辅助对账原件仅留身份、期间、摘要及完成时间，preview和directory_result不进入通用审计
SELECT public.fn_audit_track_table('finance_statement_source_reviews','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','kind','currency_id','date_from','date_to','sha256','currency_mapping_fingerprint','created_at','directory_applied_at'],true,NULL);

-- 人工核对的成本、换算、订单或加工来源决定继续完整审计，不改变业务计算
SELECT public.fn_audit_track_table('finance_sales_cost_inputs','FULL','data_change',false,NULL,true,NULL);

-- 人工核对的成本、换算、订单或加工来源决定继续完整审计，不改变业务计算
SELECT public.fn_audit_track_table('finance_plastic_template_inputs','FULL','data_change',false,NULL,true,NULL);

-- 人工核对的成本、换算、订单或加工来源决定继续完整审计，不改变业务计算
SELECT public.fn_audit_track_table('finance_material_order_references','FULL','data_change',false,NULL,true,NULL);

-- 人工核对的成本、换算、订单或加工来源决定继续完整审计，不改变业务计算
SELECT public.fn_audit_track_table('finance_copper_template_inputs','FULL','data_change',false,NULL,true,NULL);

-- 私有成本补录命令回执仅用于同请求恢复，实际人工输入在拥有表审计
SELECT public.fn_audit_track_table('finance_cost_input_operations','NONE','data_change',false,NULL,true,NULL);

-- 原表来源沿V1031只留文件及工作表身份，不复制原表预览
SELECT public.fn_audit_track_table('finance_template_sources','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','template_key','period','sha256','source_selection'],true,NULL);

-- 资产原表呈现资料为人工维护的标识/分类主档，沿用完整审计
SELECT public.fn_audit_track_table('finance_asset_template_metadata','FULL','data_change',false,NULL,true,NULL);

-- 私有资产补录命令回执仅用于同请求恢复，资产与接续决定分别审计
SELECT public.fn_audit_track_table('finance_asset_template_operations','NONE','data_change',false,NULL,true,NULL);

-- 资产接续组保留双人决定与来源指纹，成员/原分录快照保持私有
SELECT public.fn_audit_track_table('finance_asset_opening_groups','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','source_import_id','source_voucher_id','as_of','source_voucher_ids','fingerprint','status','approved_by','approved_at','revoke_actor_id','revoke_approved_by','revoked_at','row_version','created_at'],true,NULL);

-- 资产接续成员只留对象、科目、来源坐标及有效性，不复制原始/累计金额
SELECT public.fn_audit_track_table('finance_asset_opening_members','COLUMN_SCOPED','data_change',false,ARRAY['group_id','object_type','object_id','source_row','source_sha256','cost_style_id','accumulated_style_id','active'],true,NULL);

-- 原总账分录认领关系仅含真实分录与接续组UUID，完整审计身份对应
SELECT public.fn_audit_track_table('finance_asset_opening_entry_claims','FULL','data_change',false,NULL,true,NULL);

-- 资产历史读源只留对象、期间与原单元格坐标，reported_value和金额保持私有
SELECT public.fn_audit_track_table('finance_asset_template_history','COLUMN_SCOPED','data_change',false,ARRAY['id','group_id','object_type','object_id','period_from','period_to','source_import_id','source_row','source_column'],true,NULL);

-- 沿V999_8审计人员/渠道归属与确认指纹，不复制销售额
SELECT public.fn_audit_track_table('finance_sales_expense_groups','COLUMN_SCOPED','data_change',false,ARRAY['id','period','employee_id','channel','sales_confirmed','reviewed','sort_order','request_fingerprint','updated_by'],true,NULL);

-- 沿V999_8只留实际费用分录与分配请求定位
SELECT public.fn_audit_track_table('finance_sales_expense_assignments','COLUMN_SCOPED','data_change',false,ARRAY['entry_id','period','source_fingerprint','request_fingerprint','updated_by'],true,NULL);

-- 沿V999_9保留费用口径确认及锁定决定
SELECT public.fn_audit_track_table('finance_expense_analysis_periods','COLUMN_SCOPED','data_change',false,ARRAY['period','policy_confirmed','locked','updated_by'],true,NULL);

-- 沿V999_9只留经营损益备注所在期间/行和操作者，不复制备注原文
SELECT public.fn_audit_track_table('finance_operating_report_notes','COLUMN_SCOPED','data_change',false,ARRAY['period','line_key','updated_by'],true,NULL);

-- 沿V999_9只留备注导入文件摘要与完成标记
SELECT public.fn_audit_track_table('finance_expense_note_imports','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','period','sha256','applied_at'],true,NULL);

-- 沿V999_9只留制造人工归集的期间、指纹与核对决定
SELECT public.fn_audit_track_table('finance_manufacturing_labor_splits','COLUMN_SCOPED','data_change',false,ARRAY['period','source_fingerprint','request_fingerprint','reviewed','updated_by'],true,NULL);

-- 采购首笔应付启用政策是人工全局决定，继续完整审计
SELECT public.fn_audit_track_table('finance_procurement_ap_policy','FULL','data_change',false,NULL,true,NULL);

-- 首笔应付路线冻结原来源、适用政策与实际审核身份
SELECT public.fn_audit_track_table('finance_procurement_payable_routes','COLUMN_SCOPED','data_change',false,ARRAY['source_type','source_id','policy_version','approved_on','created_by','created_at'],true,NULL);

-- 暂估应付候选保留来源、状态及凭证关系；金额、汇率和原辅助/业务快照不复制到审计
SELECT public.fn_audit_track_table('finance_procurement_payable_candidates','COLUMN_SCOPED','data_change',false,ARRAY['id','source_type','source_id','bill_no','commercial_date','accrual_date','due_date','supplier_id','currency_id','settlement_method_id','inventory_style_id','pending_style_id','pending_account_code','pending_accounting_currency_id','auxiliary_id','source_fingerprint','pending_voucher_id','pending_reversal_voucher_id','status','ledger_id','recognition_id','created_by','created_at','source_reversed_at'],true,NULL);

-- 应付对账确认保留状态、双人决定与原件摘要，原件路径/名称和确认正文保持私有
SELECT public.fn_audit_track_table('finance_procurement_ap_recognitions','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','payload_hash','supplier_id','currency_id','effective_date','counterpart_confirmed_date','file_sha256','submitted_by','created_at','status','approved_by','approved_at','reversed_by','reversed_at'],true,NULL);

-- 应付确认行只留原候选、台账与正反凭证定位，不复制确认金额
SELECT public.fn_audit_track_table('finance_procurement_ap_recognition_lines','COLUMN_SCOPED','data_change',false,ARRAY['recognition_id','candidate_id','ledger_id','voucher_id','reversal_voucher_id','source_fingerprint'],true,NULL);

-- 沿原流程契约审计启停决定
SELECT public.fn_audit_track_table('finance_application_settings','COLUMN_SCOPED','authorization',false,ARRAY['id','enabled','enabled_at','updated_by'],true,NULL);

-- 沿原流程契约审计启用期间
SELECT public.fn_audit_track_table('finance_application_enable_periods','COLUMN_SCOPED','authorization',false,ARRAY['id','enabled_at','disabled_at','actor_id'],true,NULL);

-- 沿原流程契约审计明确岗位指派
SELECT public.fn_audit_track_table('finance_application_role_bindings','COLUMN_SCOPED','authorization',false,ARRAY['id','role_key','department_id','employee_id','updated_by'],true,NULL);

-- 原申请只留身份、节点与冻结指纹，原正文及金额不进入通用审计
SELECT public.fn_audit_track_table('finance_applications','COLUMN_SCOPED','data_change',false,ARRAY['id','application_no','kind','source_kind','source_id','status','current_step','submission_round','source_fingerprint','payroll_instruction_fingerprint','submitted_at','approved_at','approved_by','created_by','updated_by'],true,NULL);

-- 原审批节点保留顺序与实际决定者
SELECT public.fn_audit_track_table('finance_application_nodes','COLUMN_SCOPED','data_change',false,ARRAY['application_id','submission_round','step_no','role_key','action','status','decided_by','decided_at'],true,NULL);

-- 原申请事件只留不可变动作定位，不复制detail原文
SELECT public.fn_audit_track_table('finance_application_events','COLUMN_SCOPED','data_change',false,ARRAY['id','application_id','submission_round','event_type','step_no','actor_id','actor_employee_id','occurred_at'],true,NULL);

-- 原申请及设置回执只留请求、作用域与指纹，result保持私有
SELECT public.fn_audit_track_table('finance_application_operations','COLUMN_SCOPED','data_change',false,ARRAY['request_id','application_id','actor_id','operation','payload_hash','created_at'],true,NULL);

-- 原付款执行只留真实单据、状态及办理人，不复制结果正文
SELECT public.fn_audit_track_table('finance_application_executions','COLUMN_SCOPED','data_change',false,ARRAY['id','application_id','submission_round','request_id','doc_type','doc_id','state','paid_by','paid_at','confirmed_by','confirmed_at','reversed_by','reversed_at'],true,NULL);

-- 原报销与申请链接只留同一单据身份
SELECT public.fn_audit_track_table('finance_expense_application_links','COLUMN_SCOPED','data_change',false,ARRAY['claim_id','kind','travel_application_id','application_id','created_by'],true,NULL);

-- 结算先后依赖只留原付款/抵销/账目身份，source_snapshot保持私有
SELECT public.fn_audit_track_table('finance_supplier_settlement_dependencies','COLUMN_SCOPED','data_change',false,ARRAY['payment_line_id','offset_id','ledger_id','relation','created_at','created_by'],true,NULL);

-- 往来分类只留完整命令指纹与归属，不复制原金额
SELECT public.fn_audit_track_table('finance_open_item_classification_batches','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','ledger_id','revision','direction','party_id','currency_id','effective_from','fingerprint','created_at','created_by'],true,NULL);

-- 往来分类明细只留批次与类别，金额留在财务来源
SELECT public.fn_audit_track_table('finance_open_item_classification_parts','COLUMN_SCOPED','data_change',false,ARRAY['batch_id','category'],true,NULL);

-- 付款分摊只留请求与实际来源身份，不复制原币/现金/账面金额
SELECT public.fn_audit_track_table('finance_payment_classification_batches','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','payment_line_id','revision','source_classification_id','currency_id','fingerprint','created_at','created_by'],true,NULL);

-- 付款分类明细只留批次与类别
SELECT public.fn_audit_track_table('finance_payment_classification_parts','COLUMN_SCOPED','data_change',false,ARRAY['batch_id','category'],true,NULL);

-- 供应商抵销分摊只留请求及前后分类归属，不复制源/目标账面金额
SELECT public.fn_audit_track_table('finance_supplier_offset_classification_batches','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','offset_id','revision','source_classification_id','target_classification_id','fingerprint','created_at','created_by'],true,NULL);

-- 抵销分类明细只留批次和前后类别
SELECT public.fn_audit_track_table('finance_supplier_offset_classification_parts','COLUMN_SCOPED','data_change',false,ARRAY['batch_id','source_category','target_category'],true,NULL);

SELECT public.fn_refresh_finance_audit_metadata_projection();
