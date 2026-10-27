package com.uten.imp.migration;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.TreeMap;
import java.util.TreeSet;
import static org.junit.jupiter.api.Assertions.*;

/** V840 preserves legacy commands; later table/index/reset-policy deltas are explicit and bounded. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DailyReportMaterialReviewMigrationPostgresTest {
    private static final PostgreSQLContainer pg=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("material_review_upgrade");
    private static JdbcTemplate db;
    private static UUID actor;
    private static Map<String,Object> old;
    private static List<String> tables,indexes,resetPolicy;
    private static Map<String,Object> afterV840;
    private static Object oldMaterialSnapshotAfterV840;
    private static List<String> tablesAfterV840,indexesAfterV840,resetPolicyAfterV840;
    private static final List<String> V871_HISTORY_TABLES=List.of(
            "goods_operation_history","goods_operation_history_rows","goods_operation_history_events");
    private static final List<String> V885_HISTORY_TABLES=List.of(
            "master_operation_history","master_operation_history_rows","master_operation_history_events");
    // Independent V938/V939 CREATE TABLE/INDEX declarations: permanent task
    // identity and authorization lineage, not additional business fact tables.
    private static final List<String> V938_TO_V939_TABLE_ADDITIONS=List.of(
            "report_export_jobs","read_scope_domains","read_scope_change_events");
    private static final Map<String,String> V938_TO_V939_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("report_export_jobs_pkey","CREATE UNIQUE INDEX report_export_jobs_pkey ON public.report_export_jobs USING btree (id)"),
            Map.entry("report_export_jobs_claim_idx","CREATE INDEX report_export_jobs_claim_idx ON public.report_export_jobs USING btree (created_at, id) WHERE (status = 'PENDING'::text)"),
            Map.entry("report_export_jobs_user_idx","CREATE INDEX report_export_jobs_user_idx ON public.report_export_jobs USING btree (submitted_by, created_at DESC, id)"),
            Map.entry("report_export_jobs_lease_idx","CREATE INDEX report_export_jobs_lease_idx ON public.report_export_jobs USING btree (lease_until) WHERE (status = 'RUNNING'::text)"),
            Map.entry("report_export_jobs_expiry_idx","CREATE INDEX report_export_jobs_expiry_idx ON public.report_export_jobs USING btree (expires_at) WHERE (status = 'SUCCEEDED'::text)"),
            Map.entry("read_scope_domains_pkey","CREATE UNIQUE INDEX read_scope_domains_pkey ON public.read_scope_domains USING btree (domain)"),
            Map.entry("read_scope_change_events_pkey","CREATE UNIQUE INDEX read_scope_change_events_pkey ON public.read_scope_change_events USING btree (domain, change_txid)"));
    private static final Map<String,String> V898_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("master_record_versions_pkey","CREATE UNIQUE INDEX master_record_versions_pkey ON public.master_record_versions USING btree (id)"),
            Map.entry("ix_master_versions_object","CREATE INDEX ix_master_versions_object ON public.master_record_versions USING btree (entity_type, record_id, id DESC)"),
            Map.entry("ix_master_versions_category","CREATE INDEX ix_master_versions_category ON public.master_record_versions USING btree (entity_type, category_id, id DESC)"),
            Map.entry("ix_master_versions_overview","CREATE INDEX ix_master_versions_overview ON public.master_record_versions USING btree (entity_type, id DESC)"),
            Map.entry("ix_master_versions_command","CREATE INDEX ix_master_versions_command ON public.master_record_versions USING btree (transaction_id, record_id, id)"));
    private static final Map<String,String> V900_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("subcontract_selected_outbound_commands_pkey","CREATE UNIQUE INDEX subcontract_selected_outbound_commands_pkey ON public.subcontract_selected_outbound_commands USING btree (id)"),
            Map.entry("subcontract_selected_outbound_commands_execution_issue_id_key","CREATE UNIQUE INDEX subcontract_selected_outbound_commands_execution_issue_id_key ON public.subcontract_selected_outbound_commands USING btree (execution_issue_id)"),
            Map.entry("subcontract_selected_outbound_comm_actor_id_idempotency_key_key","CREATE UNIQUE INDEX subcontract_selected_outbound_comm_actor_id_idempotency_key_key ON public.subcontract_selected_outbound_commands USING btree (actor_id, idempotency_key)"),
            Map.entry("subcontract_selected_outbound_items_pkey","CREATE UNIQUE INDEX subcontract_selected_outbound_items_pkey ON public.subcontract_selected_outbound_items USING btree (source_item_id)"),
            Map.entry("subcontract_selected_outbound_items_execution_item_id_key","CREATE UNIQUE INDEX subcontract_selected_outbound_items_execution_item_id_key ON public.subcontract_selected_outbound_items USING btree (execution_item_id)"));
    // Reviewed V904/V908/V911/V913 source adds only retained master/import evidence tables.
    private static final List<String> V904_TO_V913_PRESERVED_TABLES=List.of(
            "goods_material_identity_evidence",
            "legacy_quantity_counter_import_sources",
            "goods_code_lifecycles",
            "goods_code_usage_facts",
            "goods_code_reuse_releases",
            "legacy_production_plan_counter_import_contexts",
            "legacy_production_plan_counter_import_sources");
    // Independent declarations reviewed against V923/V925/V928 CREATE TABLE,
    // including constraint-owned indexes; never learned from the catalog under test.
    private static final List<String> V923_TO_V928_TABLE_ADDITIONS=List.of(
            "procurement_order_termination_sources",
            "procurement_order_termination_peg_changes",
            "company_file_nodes",
            "company_file_acl",
            "stock_measurement_holds");
    private static final Map<String,String> V922_TO_V928_INDEX_ADDITIONS=Map.ofEntries(
            // V922: one finance-termination lookup on the existing approval table.
            Map.entry("idx_procurement_termination_cases","CREATE INDEX idx_procurement_termination_cases ON public.procurement_order_approval_cases USING btree (order_type, order_id, attempt DESC) WHERE (request_type <> 'ORDER'::text)"),
            // V923: two primary keys, source/transfer uniqueness and two case lookups.
            Map.entry("procurement_order_termination_sources_pkey","CREATE UNIQUE INDEX procurement_order_termination_sources_pkey ON public.procurement_order_termination_sources USING btree (id)"),
            Map.entry("procurement_order_termination_order_type_order_item_id_sour_key","CREATE UNIQUE INDEX procurement_order_termination_order_type_order_item_id_sour_key ON public.procurement_order_termination_sources USING btree (order_type, order_item_id, source_item_id)"),
            Map.entry("idx_procurement_termination_source_case","CREATE INDEX idx_procurement_termination_source_case ON public.procurement_order_termination_sources USING btree (case_id)"),
            Map.entry("procurement_order_termination_peg_changes_pkey","CREATE UNIQUE INDEX procurement_order_termination_peg_changes_pkey ON public.procurement_order_termination_peg_changes USING btree (id)"),
            Map.entry("procurement_order_termination_peg_ch_order_type_transfer_id_key","CREATE UNIQUE INDEX procurement_order_termination_peg_ch_order_type_transfer_id_key ON public.procurement_order_termination_peg_changes USING btree (order_type, transfer_id)"),
            Map.entry("idx_procurement_termination_peg_case","CREATE INDEX idx_procurement_termination_peg_case ON public.procurement_order_termination_peg_changes USING btree (case_id)"),
            // V925: immutable original identity, live names, ordering, trash,
            // idempotent requests, one clean attachment and explicit ACL subjects.
            Map.entry("company_file_nodes_pkey","CREATE UNIQUE INDEX company_file_nodes_pkey ON public.company_file_nodes USING btree (id)"),
            Map.entry("company_file_nodes_attachment_id_key","CREATE UNIQUE INDEX company_file_nodes_attachment_id_key ON public.company_file_nodes USING btree (attachment_id)"),
            Map.entry("company_file_live_name_uq","CREATE UNIQUE INDEX company_file_live_name_uq ON public.company_file_nodes USING btree (COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name)) WHERE (NOT deleted)"),
            Map.entry("company_file_parent_idx","CREATE INDEX company_file_parent_idx ON public.company_file_nodes USING btree (parent_id, deleted, \"position\", id)"),
            Map.entry("company_file_trash_idx","CREATE INDEX company_file_trash_idx ON public.company_file_nodes USING btree (deleted_at DESC, id) WHERE deleted"),
            Map.entry("company_file_request_uq","CREATE UNIQUE INDEX company_file_request_uq ON public.company_file_nodes USING btree (created_by, request_id) WHERE (request_id IS NOT NULL)"),
            Map.entry("company_file_attachment_owner_uq","CREATE UNIQUE INDEX company_file_attachment_owner_uq ON public.attachments USING btree (owner_id) WHERE (((owner_type)::text = 'COMPANY_FILE'::text) AND ((lifecycle_state)::text = 'CLEAN'::text))"),
            Map.entry("company_file_acl_pkey","CREATE UNIQUE INDEX company_file_acl_pkey ON public.company_file_acl USING btree (node_id, subject_type, subject_id, effect)"),
            Map.entry("company_file_acl_subject_idx","CREATE INDEX company_file_acl_subject_idx ON public.company_file_acl USING btree (subject_type, subject_id, node_id)"),
            // V928: NULL color participates in cohort identity; pending lookup
            // is partial without changing any original stock-balance index.
            Map.entry("stock_measurement_holds_pkey","CREATE UNIQUE INDEX stock_measurement_holds_pkey ON public.stock_measurement_holds USING btree (id)"),
            Map.entry("stock_measurement_holds_warehouse_id_goods_id_color_id_key","CREATE UNIQUE INDEX stock_measurement_holds_warehouse_id_goods_id_color_id_key ON public.stock_measurement_holds USING btree (warehouse_id, goods_id, color_id) NULLS NOT DISTINCT"),
            Map.entry("ix_stock_measurement_holds_pending","CREATE INDEX ix_stock_measurement_holds_pending ON public.stock_measurement_holds USING btree (goods_id, color_id, warehouse_id) WHERE (released_at IS NULL)"));
    private static final Map<String,String> V904_TO_V913_INDEX_ADDITIONS=Map.ofEntries(
            // V904__goods_material_identity_evidence.sql
            Map.entry("goods_material_identity_evidence_pkey","CREATE UNIQUE INDEX goods_material_identity_evidence_pkey ON public.goods_material_identity_evidence USING btree (id)"),
            Map.entry("idx_goods_material_identity_color","CREATE INDEX idx_goods_material_identity_color ON public.goods_material_identity_evidence USING btree (material_color_id) WHERE (material_color_id IS NOT NULL)"),
            Map.entry("idx_goods_material_identity_material","CREATE INDEX idx_goods_material_identity_material ON public.goods_material_identity_evidence USING btree (material_goods_id)"),
            Map.entry("idx_goods_material_identity_product","CREATE INDEX idx_goods_material_identity_product ON public.goods_material_identity_evidence USING btree (product_goods_id)"),
            Map.entry("idx_goods_material_identity_run","CREATE INDEX idx_goods_material_identity_run ON public.goods_material_identity_evidence USING btree (import_run_id) WHERE (import_run_id IS NOT NULL)"),
            Map.entry("uq_goods_material_identity_active","CREATE UNIQUE INDEX uq_goods_material_identity_active ON public.goods_material_identity_evidence USING btree (product_goods_id, material_goods_id, material_color_id) NULLS NOT DISTINCT WHERE (NOT is_deleted)"),
            // V905__batch_disabled_bom_retirement_resolution.sql
            Map.entry("idx_goods_bom_retirement_pending","CREATE INDEX idx_goods_bom_retirement_pending ON public.goods_bom_items USING btree (goods_id) WHERE (is_deleted AND (retirement_reason = 'COMPONENT_DISABLED'::text) AND (retirement_resolved_at IS NULL))"),
            // V908__legacy_initial_quantity_counter_provenance.sql
            Map.entry("legacy_quantity_counter_impor_run_id_source_kind_source_leg_key","CREATE UNIQUE INDEX legacy_quantity_counter_impor_run_id_source_kind_source_leg_key ON public.legacy_quantity_counter_import_sources USING btree (run_id, source_kind, source_legacy_id)"),
            Map.entry("legacy_quantity_counter_import_sources_pkey","CREATE UNIQUE INDEX legacy_quantity_counter_import_sources_pkey ON public.legacy_quantity_counter_import_sources USING btree (id)"),
            Map.entry("legacy_quantity_counter_import_sources_run_id_target_id_key","CREATE UNIQUE INDEX legacy_quantity_counter_import_sources_run_id_target_id_key ON public.legacy_quantity_counter_import_sources USING btree (run_id, target_id)"),
            Map.entry("legacy_quantity_counter_import_sources_target_id_key","CREATE UNIQUE INDEX legacy_quantity_counter_import_sources_target_id_key ON public.legacy_quantity_counter_import_sources USING btree (target_id)"),
            // V909__legacy_receipt_optional_order_reference_snapshot.sql
            Map.entry("ix_purchase_receipt_original_order_gap","CREATE INDEX ix_purchase_receipt_original_order_gap ON public.purchase_receipt_items USING btree (legacy_import_run_id, order_item_legacy_id) WHERE ((order_item_legacy_id IS NOT NULL) AND (order_item_id IS NULL))"),
            Map.entry("ix_subcontract_receipt_original_order_gap","CREATE INDEX ix_subcontract_receipt_original_order_gap ON public.subcontract_receipt_items USING btree (legacy_import_run_id, order_item_legacy_id) WHERE ((order_item_legacy_id IS NOT NULL) AND (order_item_id IS NULL))"),
            // V910__goods_import_operation_binding.sql
            Map.entry("idx_goods_import_batches_operation","CREATE UNIQUE INDEX idx_goods_import_batches_operation ON public.goods_import_batches USING btree (operation_id) WHERE (operation_id IS NOT NULL)"),
            // V911__unused_deleted_goods_code_reuse.sql
            Map.entry("goods_code_lifecycles_pkey","CREATE UNIQUE INDEX goods_code_lifecycles_pkey ON public.goods_code_lifecycles USING btree (goods_id)"),
            Map.entry("goods_code_reuse_releases_normalized_code_old_goods_id_key","CREATE UNIQUE INDEX goods_code_reuse_releases_normalized_code_old_goods_id_key ON public.goods_code_reuse_releases USING btree (normalized_code, old_goods_id)"),
            Map.entry("goods_code_reuse_releases_pkey","CREATE UNIQUE INDEX goods_code_reuse_releases_pkey ON public.goods_code_reuse_releases USING btree (id)"),
            Map.entry("goods_code_usage_facts_pkey","CREATE UNIQUE INDEX goods_code_usage_facts_pkey ON public.goods_code_usage_facts USING btree (goods_id)"),
            Map.entry("idx_goods_code_reuse_new_owner","CREATE INDEX idx_goods_code_reuse_new_owner ON public.goods_code_reuse_releases USING btree (new_goods_id, normalized_code)"),
            // V912__legacy_receipt_other_fee_style_snapshot.sql
            Map.entry("ix_finance_receipt_original_other_fee_style_gap","CREATE INDEX ix_finance_receipt_original_other_fee_style_gap ON public.finance_receipts USING btree (legacy_import_run_id, other_fee_style_legacy_id) WHERE ((other_fee_style_legacy_id IS NOT NULL) AND (other_fee_style_id IS NULL))"),
            // V913__legacy_production_plan_counter_provenance.sql
            Map.entry("idx_legacy_production_context_issued_txid","CREATE INDEX idx_legacy_production_context_issued_txid ON public.legacy_production_plan_counter_import_contexts USING btree (issued_txid)"),
            Map.entry("idx_legacy_production_source_color","CREATE INDEX idx_legacy_production_source_color ON public.legacy_production_plan_counter_import_sources USING btree (run_id, ((source_reference_legacy_ids ->> 'color_legacy_id'::text)))"),
            Map.entry("idx_legacy_production_source_goods","CREATE INDEX idx_legacy_production_source_goods ON public.legacy_production_plan_counter_import_sources USING btree (run_id, ((source_reference_legacy_ids ->> 'goods_legacy_id'::text)))"),
            Map.entry("idx_legacy_production_source_mgoods","CREATE INDEX idx_legacy_production_source_mgoods ON public.legacy_production_plan_counter_import_sources USING btree (run_id, ((source_reference_legacy_ids ->> 'mgoods_legacy_id'::text)))"),
            Map.entry("idx_legacy_production_source_parent","CREATE INDEX idx_legacy_production_source_parent ON public.legacy_production_plan_counter_import_sources USING btree (run_id, target_plan_id)"),
            Map.entry("idx_legacy_production_source_unit","CREATE INDEX idx_legacy_production_source_unit ON public.legacy_production_plan_counter_import_sources USING btree (run_id, ((source_reference_legacy_ids ->> 'unit_legacy_id'::text)))"),
            Map.entry("idx_legacy_production_source_upstream","CREATE INDEX idx_legacy_production_source_upstream ON public.legacy_production_plan_counter_import_sources USING btree (run_id, ((source_reference_legacy_ids ->> 's_order_item_legacy'::text)))"),
            Map.entry("legacy_production_plan_counter_impo_run_id_source_legacy_id_key","CREATE UNIQUE INDEX legacy_production_plan_counter_impo_run_id_source_legacy_id_key ON public.legacy_production_plan_counter_import_sources USING btree (run_id, source_legacy_id)"),
            Map.entry("legacy_production_plan_counter_import_contexts_pkey","CREATE UNIQUE INDEX legacy_production_plan_counter_import_contexts_pkey ON public.legacy_production_plan_counter_import_contexts USING btree (run_id)"),
            Map.entry("legacy_production_plan_counter_import_sour_run_id_target_id_key","CREATE UNIQUE INDEX legacy_production_plan_counter_import_sour_run_id_target_id_key ON public.legacy_production_plan_counter_import_sources USING btree (run_id, target_id)"),
            Map.entry("legacy_production_plan_counter_import_sources_pkey","CREATE UNIQUE INDEX legacy_production_plan_counter_import_sources_pkey ON public.legacy_production_plan_counter_import_sources USING btree (id)"),
            Map.entry("legacy_production_plan_counter_import_sources_target_id_key","CREATE UNIQUE INDEX legacy_production_plan_counter_import_sources_target_id_key ON public.legacy_production_plan_counter_import_sources USING btree (target_id)"));
    private static final Map<String,String> V885_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("master_operation_history_pkey","CREATE UNIQUE INDEX master_operation_history_pkey ON public.master_operation_history USING btree (id)"),
            Map.entry("master_operation_history_actor_id_request_id_transaction_id_key","CREATE UNIQUE INDEX master_operation_history_actor_id_request_id_transaction_id_key ON public.master_operation_history USING btree (actor_id, request_id, transaction_id)"),
            Map.entry("idx_master_history_actor","CREATE INDEX idx_master_history_actor ON public.master_operation_history USING btree (actor_id, entity_type, created_at DESC, id DESC)"),
            Map.entry("master_operation_history_rows_pkey","CREATE UNIQUE INDEX master_operation_history_rows_pkey ON public.master_operation_history_rows USING btree (operation_id, table_name, row_id)"),
            Map.entry("idx_master_history_lineage","CREATE INDEX idx_master_history_lineage ON public.master_operation_history_rows USING btree (table_name, row_id)"),
            Map.entry("master_operation_history_events_pkey","CREATE UNIQUE INDEX master_operation_history_events_pkey ON public.master_operation_history_events USING btree (id)"),
            Map.entry("idx_master_history_events_actor","CREATE INDEX idx_master_history_events_actor ON public.master_operation_history_events USING btree (actor_id, id DESC)"));
    private static final Map<String,String> V871_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("goods_operation_history_pkey","CREATE UNIQUE INDEX goods_operation_history_pkey ON public.goods_operation_history USING btree (id)"),
            Map.entry("goods_operation_history_actor_id_request_id_transaction_id_key","CREATE UNIQUE INDEX goods_operation_history_actor_id_request_id_transaction_id_key ON public.goods_operation_history USING btree (actor_id, request_id, transaction_id)"),
            Map.entry("idx_goods_operation_history_actor","CREATE INDEX idx_goods_operation_history_actor ON public.goods_operation_history USING btree (actor_id, created_at DESC, id DESC)"),
            Map.entry("goods_operation_history_rows_pkey","CREATE UNIQUE INDEX goods_operation_history_rows_pkey ON public.goods_operation_history_rows USING btree (operation_id, table_name, row_id)"),
            Map.entry("idx_goods_history_row_lineage","CREATE INDEX idx_goods_history_row_lineage ON public.goods_operation_history_rows USING btree (table_name, row_id)"),
            Map.entry("goods_operation_history_events_pkey","CREATE UNIQUE INDEX goods_operation_history_events_pkey ON public.goods_operation_history_events USING btree (id)"),
            Map.entry("idx_goods_operation_history_events_actor","CREATE INDEX idx_goods_operation_history_events_actor ON public.goods_operation_history_events USING btree (actor_id, id DESC)"));
    private static final Map<String,String> V852_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("document_unapprovals_draft_unique","CREATE UNIQUE INDEX document_unapprovals_draft_unique ON public.document_unapprovals USING btree (family, draft_id)"),
            Map.entry("document_unapprovals_original_unique","CREATE UNIQUE INDEX document_unapprovals_original_unique ON public.document_unapprovals USING btree (family, original_id)"),
            Map.entry("document_unapprovals_pkey","CREATE UNIQUE INDEX document_unapprovals_pkey ON public.document_unapprovals USING btree (id)"),
            Map.entry("document_unapprovals_request_unique","CREATE UNIQUE INDEX document_unapprovals_request_unique ON public.document_unapprovals USING btree (created_by, family, request_key)"),
            Map.entry("procurement_inspection_items_item_tranche_uk","CREATE UNIQUE INDEX procurement_inspection_items_item_tranche_uk ON public.procurement_inspection_items USING btree (receipt_type, receipt_item_id, quantity_tranche)"),
            Map.entry("idx_purchase_receipt_item_finance_case","CREATE INDEX idx_purchase_receipt_item_finance_case ON public.purchase_receipt_items USING btree (finance_approval_case_id)"),
            Map.entry("idx_subcontract_receipt_item_finance_case","CREATE INDEX idx_subcontract_receipt_item_finance_case ON public.subcontract_receipt_items USING btree (finance_approval_case_id)"),
            Map.entry("idx_purchase_request_qty_revision_document","CREATE INDEX idx_purchase_request_qty_revision_document ON public.purchase_request_qty_revisions USING btree (request_id, request_item_id, expected_version)"),
            Map.entry("purchase_request_qty_revision_request_item_id_expected_vers_key","CREATE UNIQUE INDEX purchase_request_qty_revision_request_item_id_expected_vers_key ON public.purchase_request_qty_revisions USING btree (request_item_id, expected_version)"),
            Map.entry("purchase_request_qty_revisions_created_txid_request_item_id_key","CREATE UNIQUE INDEX purchase_request_qty_revisions_created_txid_request_item_id_key ON public.purchase_request_qty_revisions USING btree (created_txid, request_item_id)"),
            Map.entry("purchase_request_qty_revisions_pkey","CREATE UNIQUE INDEX purchase_request_qty_revisions_pkey ON public.purchase_request_qty_revisions USING btree (id)"),
            Map.entry("idx_poi_price_context","CREATE INDEX idx_poi_price_context ON public.purchase_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_sori_price_context","CREATE INDEX idx_sori_price_context ON public.subcontract_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_soi_price_context","CREATE INDEX idx_soi_price_context ON public.sales_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_po_price_period","CREATE INDEX idx_po_price_period ON public.purchase_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_sco_price_period","CREATE INDEX idx_sco_price_period ON public.subcontract_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_so_price_period","CREATE INDEX idx_so_price_period ON public.sales_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_procurement_price_history_snapshot","CREATE INDEX idx_procurement_price_history_snapshot ON public.procurement_order_approval_cases USING gin (submission_snapshot jsonb_path_ops)"));
    @BeforeAll static void migrate() {
        pg.start();com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target("839").load().migrate();
        db=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
        actor=UUID.randomUUID();UUID department=UUID.randomUUID(),employee=UUID.randomUUID(),report=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"MAT-V3-D","材料审核迁移车间");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"MAT-V3-E","材料审核迁移员工",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",actor,employee,"material-review-migration");
        db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,'SR20200101000001',DATE '2020-01-01',0,?)",report,employee);
        db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version) VALUES(?,? ,repeat('a',64),?,?,'APPROVE',2,0)",actor,"old-reviewed-material-key",report,actor);
        old=db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor);
        tables=tables();indexes=indexes();resetPolicy=resetPolicy();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target("840").load().migrate();
        afterV840=oldCommand();
        oldMaterialSnapshotAfterV840=db.queryForObject("SELECT material_review_snapshot FROM production_daily_report_commands WHERE actor_user_id=?",Object.class,actor);
        tablesAfterV840=tables();indexesAfterV840=indexes();resetPolicyAfterV840=resetPolicy();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop(){pg.stop();}
    @Test void oldApprovalBytesAndReviewMeaningStayExactlyTheSame() {
        assertEquals(old,afterV840);
        assertNull(oldMaterialSnapshotAfterV840);
        assertEquals(old,oldCommand());
        assertNull(db.queryForObject("SELECT material_review_snapshot FROM production_daily_report_commands WHERE actor_user_id=?",Object.class,actor));
        assertEquals(tables,tablesAfterV840);assertEquals(indexes,indexesAfterV840);assertEquals(resetPolicy,resetPolicyAfterV840);
    }
    @Test void laterForwardMigrationsHaveOnlyTheExactDeclaredTableIndexAndResetPolicyDelta() {
        TreeSet<String> expectedTables=new TreeSet<>(tablesAfterV840);
        assertTrue(expectedTables.add("document_unapprovals"));
        assertTrue(expectedTables.add("purchase_request_qty_revisions"));
        assertTrue(expectedTables.add("sms_gateway_settings"));
        // V873/V874 (ADR-183): 远程 TOTP 凭据与外网策略单例, 均随业务清空保留。
        assertTrue(expectedTables.add("staff_mfa"));
        assertTrue(expectedTables.add("remote_access_policy"));
        // V879 官网管理与询盘并入: 询盘时间线(append-only)、连接配置单例与桥接诊断单例。
        assertTrue(expectedTables.add("website_inquiry_events"));
        assertTrue(expectedTables.add("website_management_settings"));
        assertTrue(expectedTables.add("website_bridge_status"));
        // V888 retains catalog-deletion markers independently of business rows.
        assertTrue(expectedTables.add("platform_column_definition_deletions"));
        assertTrue(expectedTables.add("business_column_deletions"));
        // V890 preserves the explicit market association with its goods master.
        assertTrue(expectedTables.add("goods_market_reference_bindings"));
        // V894 adds saved permission snapshots, independently of existing accounts and command evidence.
        assertTrue(expectedTables.add("permission_templates"));
        // V898 retains object versions; V900 records selected outbound execution lineage.
        assertTrue(expectedTables.add("master_record_versions"));
        assertTrue(expectedTables.add("subcontract_selected_outbound_commands"));
        assertTrue(expectedTables.add("subcontract_selected_outbound_items"));
        V904_TO_V913_PRESERVED_TABLES.forEach(table->assertTrue(expectedTables.add(table)));
        V923_TO_V928_TABLE_ADDITIONS.forEach(table->assertTrue(expectedTables.add(table)));
        // V937: verified, append-only identity evidence is preserved independently
        // of business rows; it is an authorization decision with FULL row audit.
        assertTrue(expectedTables.add("employee_identity_aliases"));
        V938_TO_V939_TABLE_ADDITIONS.forEach(table->assertTrue(expectedTables.add(table)));
        V871_HISTORY_TABLES.forEach(table->assertTrue(expectedTables.add(table)));
        V885_HISTORY_TABLES.forEach(table->assertTrue(expectedTables.add(table)));
        assertEquals(expectedTables.stream().toList(),tables());
        TreeMap<String,String> expectedIndexes=catalogMap(indexesAfterV840);
        assertEquals("CREATE UNIQUE INDEX procurement_inspection_items_item_uk ON public.procurement_inspection_items USING btree (receipt_type, receipt_item_id)",
                expectedIndexes.remove("procurement_inspection_items_item_uk"));
        V852_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A declared new index must not replace an existing index: "+name));
        assertNull(expectedIndexes.put("sms_gateway_settings_pkey",
                "CREATE UNIQUE INDEX sms_gateway_settings_pkey ON public.sms_gateway_settings USING btree (id)"));
        // V873/V874 (ADR-183): 两张新表的主键索引是各自的全部索引增量。
        assertNull(expectedIndexes.put("staff_mfa_pkey",
                "CREATE UNIQUE INDEX staff_mfa_pkey ON public.staff_mfa USING btree (user_id)"));
        assertNull(expectedIndexes.put("remote_access_policy_pkey",
                "CREATE UNIQUE INDEX remote_access_policy_pkey ON public.remote_access_policy USING btree (singleton_id)"));
        // V879: 三张新表的主键索引 + 询盘时间线的 (inquiry_id, created_at, id) 读取索引。
        assertNull(expectedIndexes.put("website_inquiry_events_pkey",
                "CREATE UNIQUE INDEX website_inquiry_events_pkey ON public.website_inquiry_events USING btree (id)"));
        assertNull(expectedIndexes.put("idx_website_inquiry_events",
                "CREATE INDEX idx_website_inquiry_events ON public.website_inquiry_events USING btree (inquiry_id, created_at, id)"));
        assertNull(expectedIndexes.put("website_management_settings_pkey",
                "CREATE UNIQUE INDEX website_management_settings_pkey ON public.website_management_settings USING btree (id)"));
        assertNull(expectedIndexes.put("website_bridge_status_pkey",
                "CREATE UNIQUE INDEX website_bridge_status_pkey ON public.website_bridge_status USING btree (id)"));
        assertNull(expectedIndexes.put("platform_column_definition_deletions_pkey",
                "CREATE UNIQUE INDEX platform_column_definition_deletions_pkey ON public.platform_column_definition_deletions USING btree (definition_id)"));
        assertNull(expectedIndexes.put("business_column_deletions_pkey",
                "CREATE UNIQUE INDEX business_column_deletions_pkey ON public.business_column_deletions USING btree (column_id)"));
        assertNull(expectedIndexes.put("goods_market_reference_bindings_pkey",
                "CREATE UNIQUE INDEX goods_market_reference_bindings_pkey ON public.goods_market_reference_bindings USING btree (goods_id)"));
        assertNull(expectedIndexes.put("permission_templates_pkey",
                "CREATE UNIQUE INDEX permission_templates_pkey ON public.permission_templates USING btree (id)"));
        assertNull(expectedIndexes.put("permission_templates_name_active_uq",
                "CREATE UNIQUE INDEX permission_templates_name_active_uq ON public.permission_templates USING btree (lower(btrim((name)::text))) WHERE (NOT is_deleted)"));
        // V895 bounds retained-responsibility lookup to the cancelled actions of the current analysis.
        assertNull(expectedIndexes.put("idx_preplan_cancelled_action_analysis",
                "CREATE INDEX idx_preplan_cancelled_action_analysis ON public.preplan_supply_actions USING btree (analysis_id, id) WHERE (status = 'CANCELLED'::text)"));
        // V870 adds a nullable correction-source relationship to append-only
        // employment events; its one new partial index is an explicit delta.
        assertNull(expectedIndexes.put("idx_employment_history_correction_source",
                "CREATE INDEX idx_employment_history_correction_source ON public.employment_history USING btree (corrects_history_id) WHERE (corrects_history_id IS NOT NULL)"));
        V871_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A history index must not replace an existing index: "+name));
        V885_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A master history index must not replace an existing index: "+name));
        V898_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "An object version index must not replace an existing index: "+name));
        V900_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A selected outbound index must not replace an existing index: "+name));
        V904_TO_V913_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A declared evidence/index delta must not replace an existing index: "+name));
        assertEquals(19,V922_TO_V928_INDEX_ADDITIONS.size());
        V922_TO_V928_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A termination/library/measurement index must not replace an existing index: "+name));
        // Explicit V937 CREATE TABLE/INDEX deltas, not learned from the catalog under test.
        assertNull(expectedIndexes.put("employee_identity_aliases_pkey",
                "CREATE UNIQUE INDEX employee_identity_aliases_pkey ON public.employee_identity_aliases USING btree (alias_employee_id)"));
        assertNull(expectedIndexes.put("employee_identity_aliases_canonical_idx",
                "CREATE INDEX employee_identity_aliases_canonical_idx ON public.employee_identity_aliases USING btree (canonical_employee_id)"));
        assertEquals(7,V938_TO_V939_INDEX_ADDITIONS.size());
        V938_TO_V939_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A retained export/authorization index must not replace an existing index: "+name));
        assertEquals(expectedIndexes,catalogMap(indexes()));
        Map.of("report_export_jobs",List.of("trg_guard_report_export_identity","trg_report_export_jobs_no_truncate"),
                "read_scope_domains",List.of("trg_read_scope_domains_immutable","trg_read_scope_domains_no_truncate"),
                "read_scope_change_events",List.of("trg_read_scope_event_insert","trg_read_scope_event_immutable","trg_read_scope_event_no_truncate"))
                .forEach((table,names)->names.forEach(trigger->assertEquals("A",db.queryForObject(
                        "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid=?::regclass AND tgname=?",String.class,"public."+table,trigger),
                        "Retained export/authorization evidence keeps its exact ALWAYS guard: "+trigger)));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='public.report_export_jobs'::regclass "
                + "AND tgfoid='public.fn_audit()'::regprocedure AND tgenabled='A'",Integer.class),
                "Export task state keeps its declared insert/delete and scoped update audit");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid IN('public.read_scope_domains'::regclass,'public.read_scope_change_events'::regclass) "
                + "AND tgfoid='public.fn_audit()'::regprocedure",Integer.class),
                "Technical read-scope lineage must not duplicate the audited authorization source rows");
        assertTrue(db.queryForObject("SELECT obj_description('public.employee_identity_aliases'::regclass,'pg_class') LIKE 'PRESERVE %'",Boolean.class));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='public.employee_identity_aliases'::regclass "
                + "AND tgfoid='public.fn_audit()'::regprocedure AND tgenabled='A' "
                + "AND substring(tgargs FROM 1 FOR 14)=convert_to('authorization','UTF8')||decode('00','hex')",Integer.class),
                "Verified identity evidence keeps FULL/authorization insert/delete and update audit");
        assertNull(db.queryForObject("SELECT to_regprocedure('public.business_data_reset()')::text",String.class));
        assertEquals(MigrationRehearsalSupport.CURRENT_HEAD_VERSION,
                db.queryForObject("SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1",String.class));
    }
    @Test void incompleteV3ProofOrForeignReportSnapshotCannotBeRecorded() {
        UUID report=newReport("SR20200101000002");
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}",null));
        assertThrows(Exception.class,()->insertV3(report,"{}","[]"));
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+UUID.randomUUID()+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
    }
    @Test void validV3EmptyMaterialSnapshotIsAppendOnly() {
        UUID report=newReport("SR20200101000003");
        insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]");
        assertThrows(Exception.class,()->db.update("UPDATE production_daily_report_commands SET material_decisions='[]'::jsonb WHERE report_id=?",report));
        assertThrows(Exception.class,()->db.update("DELETE FROM production_daily_report_commands WHERE report_id=?",report));
        assertEquals(3,db.queryForObject("SELECT approval_protocol_version FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
        assertNull(db.queryForObject("SELECT to_regprocedure('public.business_data_reset()')::text",String.class));
    }
    private static UUID newReport(String billNo){UUID report=UUID.randomUUID();UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,?,DATE '2020-01-01',0,?)",report,billNo,employee);return report;}
    private static Map<String,Object> oldCommand(){return db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor);}
    private static TreeMap<String,String> catalogMap(List<String> rows){TreeMap<String,String> result=new TreeMap<>();for(String row:rows){int separator=row.indexOf('|');assertTrue(separator>0);assertNull(result.put(row.substring(0,separator),row.substring(separator+1)));}return result;}
    private static void insertV3(UUID report,String snapshot,String decisions){db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version,material_review_fingerprint,material_review_snapshot,material_decisions) VALUES(?,?,repeat('b',64),?,?,'APPROVE',3,0,repeat('b',64),CAST(? AS jsonb),CAST(? AS jsonb))",actor,"new-v3-migration-"+UUID.randomUUID(),report,actor,snapshot,decisions);}
    private static List<String> tables(){return db.queryForList("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",String.class);}
    private static List<String> indexes(){return db.queryForList("SELECT indexname||'|'||indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexname",String.class);}
    private static List<String> resetPolicy(){return db.queryForList("SELECT table_name||'|'||disposition FROM fn_business_reset_table_policy() ORDER BY table_name",String.class);}
}
