package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.flywaydb.core.api.MigrationVersion;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;


/**
 * 行级审计三清单契约(ADR-105, V670 起)。
 *
 * <p>每张 public 业务表必须且只能归入一类, 每条带理由:
 * <ul>
 *   <li>FULL: 整行审计(INSERT/DELETE 存整行, UPDATE 只存变化键), 人工维护的主档、权限、单据;</li>
 *   <li>COLUMN_SCOPED: 只审计人为决定的列, 派生列变化不留行审计;</li>
 *   <li>NONE: 不挂行级审计(派生投影、队列、编号预留、只追加流水、遗留只读数据、技术表)。</li>
 * </ul>
 * 废除 V169 起「除技术白名单外全表必审、审计触发器不许带 WHEN/列清单」的规则。V670 按本清单
 * 挂/拆触发器; 之后新建的表必须在这里登记, 属于 FULL/COLUMN_SCOPED 的由建表迁移调用
 * {@code fn_audit_track_table} 挂审计, 不许手写 CREATE TRIGGER trg_audit_*。
 * 真库上的触发器形态由 {@link AuditTriggerCoveragePostgresTest} 按同一清单核对。
 */
class AuditTriggerCoverageMigrationContractTest {

    static final Path MIGRATION_ROOT = Path.of("src/main/resources/db/migration");
    static final int POLICY_BASELINE_VERSION = 670;
    static final Path POLICY_BASELINE =
            MIGRATION_ROOT.resolve("V670__audit_three_list_policy_change_only_rows.sql");
    private static final Pattern MIGRATION_FILE = Pattern.compile("^V(\\d+)(?:_\\d+)*__.+\\.sql$");
    private static final String IDENT =
            "(?:\"?public\"?\\s*\\.\\s*)?\"?([a-z_][a-z0-9_]*)\"?";
    static final Pattern CREATE_TABLE = Pattern.compile(
            "(?i)\\bCREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(?!IF\\s)" + IDENT
                    + "(?![A-Za-z0-9_'%|$])(\\s+PARTITION\\s+OF)?");
    private static final Pattern DROP_TABLE = Pattern.compile(
            "(?i)\\bDROP\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?((?:(?:\"?public\"?\\s*\\.\\s*)?\"?[a-z_][a-z0-9_]*\"?"
                    + "\\s*,\\s*)*(?:\"?public\"?\\s*\\.\\s*)?\"?[a-z_][a-z0-9_]*\"?)");
    private static final Pattern RENAME_TABLE = Pattern.compile(
            "(?i)\\bALTER\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?(?:ONLY\\s+)?" + IDENT
                    + "\\s+RENAME\\s+TO\\s+\"?([a-z_][a-z0-9_]*)\"?");
    private static final Pattern FULL_CALL = Pattern.compile(
            "(?s)fn_audit_track_table\\(t, 'FULL', '([a-z_]+)', (true|false)\\)\\s+FROM unnest\\(ARRAY\\[(.*?)]\\) AS t;");
    private static final Pattern SCOPED_CALL = Pattern.compile(
            "(?s)fn_audit_track_table\\(\\s*'([a-z_][a-z0-9_]*)'\\s*,\\s*'COLUMN_SCOPED'\\s*,\\s*'([a-z_]+)'\\s*,\\s*(true|false)\\s*,\\s*"
                    + "ARRAY\\s*\\[(.*?)]\\s*,\\s*(true|false)\\s*(?:,\\s*(?:'([a-z_][a-z0-9_.]*\\(\\))'|(?i:NULL(?:\\s*::\\s*text)?)))?"
                    + "(?:,\\s*(?:'([a-z_][a-z0-9_.]*\\(\\))'|(?i:NULL(?:\\s*::\\s*text)?)))?\\s*\\);");
    private static final Pattern REGISTRATION = Pattern.compile(
            "fn_audit_track_table\\(\\s*'([a-z_][a-z0-9_]*)'\\s*,\\s*'(FULL|COLUMN_SCOPED|NONE)'");
    private static final Pattern QUOTED = Pattern.compile("'([a-z_][a-z0-9_]*)'");
    /** Flyway 自己建的表, 不在迁移脚本里。 */
    private static final Set<String> CREATED_OUTSIDE_MIGRATIONS = Set.of("flyway_schema_history");
    private static final Set<String> CATEGORIES = Set.of("data_change", "authorization", "system");

    record FullGroup(String key, String category, boolean redacted, String reason, Set<String> tables) {
    }

    /** V970 外网登录简化删除的表: 建表迁移里的历史 fn_audit_track_table 登记保留原样,
     *  三清单不再收录, 活库中也不存在; 只在迁移扫描中放行, 不改变任何现存表的政策。 */
    static final java.util.Set<String> DROPPED_TRACKED_TABLES = java.util.Set.of("staff_mfa", "remote_access_policy");

    /**
     * V1006 以同一个动态 EXECUTE format 模板给工资/总账清偿十张表绑 fn_audit()
     * （两个 DO 块各引用一次模板，运行时表名来自数组，静态不可枚举）。
     * 模板原文与出现次数在此钉死，文件字节由 {@link #DYNAMIC_LEGACY_AUDIT_FILE}
     * 按 sha256 锁定；十张表已由 V1042 按同一列清单显式重登记为
     * COLUMN_SCOPED（由「基线之后登记」用例逐表核对），模板本身仅此一处合法。
     */
    private static final String DYNAMIC_LEGACY_AUDIT_TEMPLATE =
            "execute format('create trigger %i after insert or update or delete on %i"
                    + " for each row execute function fn_audit()',table_name||'_audit',table_name);";
    private static final int DYNAMIC_LEGACY_AUDIT_TEMPLATE_OCCURRENCES = 2;
    /** V1006 的文件字节钉死；模板豁免只在列出的文件上生效，其它文件出现同样模板依旧失败。 */
    private static final java.util.Map.Entry<String, String> DYNAMIC_LEGACY_AUDIT_FILE =
            java.util.Map.entry("V1006__payroll_original_fact_payment_bridge.sql",
                    "6bb5ee75c493a7857d2d40b8bef8971c8f357fc20403f1ba1eb373ae28d06691");

    /**
     * Applied mistakes remain immutable; the hand-written audit trigger of each pinned file
     * is excused only while the exact public-policy registration exists in its {@code forwardFile}
     * (V975 先例：公共入口只按 OID 换掉审计函数触发器，保留业务守卫与历史)。
     * 一个文件可有多条；每条的历史触发器原文只允许出现一次。
     */
    private record ForwardAuditRepair(String file, String table, String sha256,
                                      String forwardFile, String legacyTrigger) {
        private ForwardAuditRepair(String file, String table, String sha256) {
            this(file, table, sha256, "V975__finance_asset_audit_policy_registration.sql");
        }
        private ForwardAuditRepair(String file, String table, String sha256, String forwardFile) {
            this(file, table, sha256, forwardFile,
                    "create trigger trg_audit_" + table + " after insert or update or delete on " + table
                            + " for each row execute function fn_audit();");
        }
    }

    /**
     * 2026-11 财务复刻/精度批次：V1001/V1002/V1004/V1007/V1023 已应用且不可回改，
     * 其中手写的 fn_audit() 触发器按 V975 先例由 V1042 前向登记取代；
     * 原字节由 sha256 钉死，改任何一个字符都会在此暴露。
     * V1004/V1023 的历史触发器名与表名不完全一致（缺尾部 s / 用简写），
     * 因此这三条显式给出触发器原文。
     */
    private static final Map<Integer, List<ForwardAuditRepair>> FORWARD_AUDIT_REPAIRS = Map.of(
            973, List.of(new ForwardAuditRepair("V973__financial_statement_template_bindings.sql",
                    "finance_report_line_confirmations", "c0a05fbb509c4af6fed0dbbc28af1e6bb7da955fc15dc0c7739ee31a4882cbe7")),
            974, List.of(new ForwardAuditRepair("V974__asset_opening_and_recognition_reversal.sql",
                    "finance_asset_recognition_reversals", "dee0805ec5a590498880307007b6f813c035fab684de4b9b3423edacfe532c4c")),
            1001, List.of(
                    new ForwardAuditRepair("V1001__business_application_workflows.sql", "business_applications",
                            "ca6fefbb363b5c36af47787f3112cb1e04df08fb5ef6d4cf53ea890aa2e8a43c",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1001__business_application_workflows.sql", "business_application_events",
                            "ca6fefbb363b5c36af47787f3112cb1e04df08fb5ef6d4cf53ea890aa2e8a43c",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1001__business_application_workflows.sql", "business_application_submissions",
                            "ca6fefbb363b5c36af47787f3112cb1e04df08fb5ef6d4cf53ea890aa2e8a43c",
                            "V1042__finance_reproduction_audit_policy_registration.sql")),
            1002, List.of(new ForwardAuditRepair("V1002__department_approval_substitution_policy.sql",
                    "department_approval_policies", "b8c390e8969153bb65ab05c956cc61cc36886bdd3baf80f47d2ee1fa13758f26",
                    "V1042__finance_reproduction_audit_policy_registration.sql")),
            1004, List.of(
                    new ForwardAuditRepair("V1004__finance_statement_document_evidence.sql", "finance_statement_profiles",
                            "383816335a169301a4e727eb0b8ad0a276f5802974a7aa79b5334814c32ed30c",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1004__finance_statement_document_evidence.sql", "finance_statement_document_reviews",
                            "383816335a169301a4e727eb0b8ad0a276f5802974a7aa79b5334814c32ed30c",
                            "V1042__finance_reproduction_audit_policy_registration.sql",
                            "create trigger trg_audit_finance_statement_reviews after insert or update or delete"
                                    + " on finance_statement_document_reviews for each row execute function fn_audit();")),
            1007, List.of(
                    new ForwardAuditRepair("V1007__supplier_advance_asset_lifecycle.sql", "finance_supplier_advances",
                            "e2df13f279dc78e2f70081bad003d5faca977f703aaae3dba568c9d135b7e125",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1007__supplier_advance_asset_lifecycle.sql", "finance_supplier_advance_parts",
                            "e2df13f279dc78e2f70081bad003d5faca977f703aaae3dba568c9d135b7e125",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1007__supplier_advance_asset_lifecycle.sql", "finance_supplier_advance_applications",
                            "e2df13f279dc78e2f70081bad003d5faca977f703aaae3dba568c9d135b7e125",
                            "V1042__finance_reproduction_audit_policy_registration.sql"),
                    new ForwardAuditRepair("V1007__supplier_advance_asset_lifecycle.sql", "finance_supplier_advance_refunds",
                            "e2df13f279dc78e2f70081bad003d5faca977f703aaae3dba568c9d135b7e125",
                            "V1042__finance_reproduction_audit_policy_registration.sql")),
            1023, List.of(
                    new ForwardAuditRepair("V1023__document_specific_payable_fee_decisions.sql", "finance_payable_statement_adjustments",
                            "92228bfb740da5c147b632fb078512aae0931d505f825e8f8c9290ad2e9997fa",
                            "V1042__finance_reproduction_audit_policy_registration.sql",
                            "create trigger trg_audit_payable_statement_adjustment after insert or update or delete"
                                    + " on finance_payable_statement_adjustments for each row execute function fn_audit();"),
                    new ForwardAuditRepair("V1023__document_specific_payable_fee_decisions.sql", "finance_payable_statement_adjustment_lines",
                            "92228bfb740da5c147b632fb078512aae0931d505f825e8f8c9290ad2e9997fa",
                            "V1042__finance_reproduction_audit_policy_registration.sql",
                            "create trigger trg_audit_payable_statement_adjustment_line after insert or update or delete"
                                    + " on finance_payable_statement_adjustment_lines for each row execute function fn_audit();")),
            1108, List.of(new ForwardAuditRepair("V1108__same_sales_source_stock_adoption.sql",
                    "preplan_sales_stock_adoptions", "8b3547c1ae607eb7f51da7eb0d3f7e0a3e08bbcd224ffb3d48484df269cab30a",
                    "V1112__stock_adoption_canonical_audit_registration.sql",
                    "create trigger trg_audit_preplan_sales_stock_adoption after insert or update or delete"
                            + " on preplan_sales_stock_adoptions for each row execute function fn_audit();")),
            1109, List.of(
                    new ForwardAuditRepair("V1109__preplan_public_physical_stock_adoption.sql", "preplan_physical_stock_claim_commands",
                            "b6c26c976e50878782172d295efc84c5e78b850ea14cc803c5c0046223f01adb",
                            "V1112__stock_adoption_canonical_audit_registration.sql"),
                    new ForwardAuditRepair("V1109__preplan_public_physical_stock_adoption.sql", "preplan_physical_stock_claim_allocations",
                            "b6c26c976e50878782172d295efc84c5e78b850ea14cc803c5c0046223f01adb",
                            "V1112__stock_adoption_canonical_audit_registration.sql"),
                    new ForwardAuditRepair("V1109__preplan_public_physical_stock_adoption.sql", "preplan_physical_stock_formalizations",
                            "b6c26c976e50878782172d295efc84c5e78b850ea14cc803c5c0046223f01adb",
                            "V1112__stock_adoption_canonical_audit_registration.sql")));

    /** Previously applied financial subversions were missed by the integer-only scanner.
     * Every allowance pins the complete source bytes and exact trigger count, and is
     * conditional on its table's explicit metadata-only registration in V1059. */
    private record PinnedSubversionAudit(String file, String sha256, int staticTriggerCount) { }
    private static final List<PinnedSubversionAudit> PINNED_SUBVERSION_AUDITS = List.of(
            new PinnedSubversionAudit("V999_10__procurement_reconciliation_first_payables.sql",
                    "eebc2f9643998323d87a86b5422a38587ea0cfa3eb1a592f748ac5a6b8567723", 5),
            new PinnedSubversionAudit("V999_13__finance_open_item_classification_allocations.sql",
                    "6137d5044dcb1ae0b5432c257c7b8ed951e4f55f4f1cc9fe14cae573adeadf85", 1),
            new PinnedSubversionAudit("V999_1__finance_chart_code_imports.sql",
                    "3668d1c45796ff017baf2cf302c17c5c01815be372f47125e1d0e4914195b5dd", 2),
            new PinnedSubversionAudit("V999_2__financial_voucher_evidence_and_auxiliary_allocations.sql",
                    "d077b5f8ee5c91e860d1a79245b49ae517fe810ccf9628379386766e2e0f2663", 3),
            new PinnedSubversionAudit("V999_3__finance_accounting_source_continuation.sql",
                    "376947bd9e26f69affca209629834d85ee8ff96a8ad88550a389473d2e8003f9", 2),
            new PinnedSubversionAudit("V999_4__finance_auxiliary_items.sql",
                    "2e4b5b28309bf51edc45499a0d956d7721af3db6f4980bdac903201cda884879", 4),
            new PinnedSubversionAudit("V999_5__finance_statement_source_reviews.sql",
                    "e453b84f637b07cab7d50efe0ff1665e9309942e7e1bcc754d5493e63b46e2d1", 1),
            new PinnedSubversionAudit("V999_6__finance_cost_template_inputs.sql",
                    "4a2531b6e1c6ed26d875c5706e340f1716dfb23aa9c285dbca18a809ffbbcb18", 4),
            new PinnedSubversionAudit("V999_7__finance_asset_template_facts.sql",
                    "ab59e77ae658abf4960370270bddb7a1a036e81c4b8050d9c2f08770d192cc42", 4));
    private record LegacyFinanceAudit(String sha256,List<String> triggers,List<String> tables,String dynamicTemplate) { }
    private static final Map<String,LegacyFinanceAudit> SEGMENTED_FINANCE_AUDIT_REPAIRS=Map.ofEntries(
            Map.entry("V999_1__finance_chart_code_imports.sql",new LegacyFinanceAudit("3668d1c45796ff017baf2cf302c17c5c01815be372f47125e1d0e4914195b5dd",
                    List.of("create trigger trg_audit_finance_chart_codes after insert or update or delete on finance_chart_codes for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_chart_code_styles after insert or update or delete on finance_chart_code_styles for each row execute function fn_audit();"),
                    List.of("finance_chart_codes","finance_chart_code_styles"),
                    null)),
            Map.entry("V999_10__procurement_reconciliation_first_payables.sql",new LegacyFinanceAudit("eebc2f9643998323d87a86b5422a38587ea0cfa3eb1a592f748ac5a6b8567723",
                    List.of("create trigger trg_audit_finance_procurement_ap_policy after insert or update or delete on finance_procurement_ap_policy for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_procurement_payable_routes after insert or update or delete on finance_procurement_payable_routes for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_procurement_payable_candidates after insert or update or delete on finance_procurement_payable_candidates for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_procurement_ap_recognitions after insert or update or delete on finance_procurement_ap_recognitions for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_procurement_ap_recognition_lines after insert or update or delete on finance_procurement_ap_recognition_lines for each row execute function fn_audit();"),
                    List.of("finance_procurement_ap_policy","finance_procurement_payable_routes","finance_procurement_payable_candidates","finance_procurement_ap_recognitions","finance_procurement_ap_recognition_lines"),
                    null)),
            Map.entry("V999_13__finance_open_item_classification_allocations.sql",new LegacyFinanceAudit("6137d5044dcb1ae0b5432c257c7b8ed951e4f55f4f1cc9fe14cae573adeadf85",
                    List.of("create trigger trg_finance_settlement_dependencies_audit after insert on finance_supplier_settlement_dependencies for each row execute function fn_audit();"),
                    List.of("finance_supplier_settlement_dependencies","finance_open_item_classification_batches","finance_open_item_classification_parts","finance_payment_classification_batches","finance_payment_classification_parts","finance_supplier_offset_classification_batches","finance_supplier_offset_classification_parts"),
                    "execute format('create trigger %i after insert on %i for each row execute function fn_audit()',table_name||'_audit',table_name);")),
            Map.entry("V999_2__financial_voucher_evidence_and_auxiliary_allocations.sql",new LegacyFinanceAudit("d077b5f8ee5c91e860d1a79245b49ae517fe810ccf9628379386766e2e0f2663",
                    List.of("create trigger trg_audit_finance_gl_voucher_evidence after insert on finance_gl_voucher_evidence for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_gl_entry_allocations after insert or update or delete on finance_gl_entry_allocations for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_gl_aux_opening after insert on finance_gl_auxiliary_opening_evidence for each row execute function fn_audit();"),
                    List.of("finance_gl_voucher_evidence","finance_gl_entry_allocations","finance_gl_auxiliary_opening_evidence"),
                    null)),
            Map.entry("V999_3__finance_accounting_source_continuation.sql",new LegacyFinanceAudit("376947bd9e26f69affca209629834d85ee8ff96a8ad88550a389473d2e8003f9",
                    List.of("create trigger trg_audit_finance_accounting_batch after insert or update or delete on finance_accounting_import_batches for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_gl_baseline after insert on finance_gl_opening_baselines for each row execute function fn_audit();"),
                    List.of("finance_accounting_import_batches","finance_gl_opening_baselines"),
                    null)),
            Map.entry("V999_4__finance_auxiliary_items.sql",new LegacyFinanceAudit("2e4b5b28309bf51edc45499a0d956d7721af3db6f4980bdac903201cda884879",
                    List.of("create trigger trg_audit_finance_auxiliary_parties after insert or update or delete on finance_auxiliary_parties for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_auxiliary_items after insert or update or delete on finance_auxiliary_items for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_account_auxiliary_rules after insert or update or delete on finance_account_auxiliary_rules for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_account_auxiliary_bindings after insert or update or delete on finance_account_auxiliary_bindings for each row execute function fn_audit();"),
                    List.of("finance_auxiliary_parties","finance_auxiliary_items","finance_account_auxiliary_rules","finance_account_auxiliary_bindings"),
                    null)),
            Map.entry("V999_5__finance_statement_source_reviews.sql",new LegacyFinanceAudit("e453b84f637b07cab7d50efe0ff1665e9309942e7e1bcc754d5493e63b46e2d1",
                    List.of("create trigger trg_audit_finance_statement_source_reviews after insert or update or delete on finance_statement_source_reviews for each row execute function fn_audit();"),
                    List.of("finance_statement_source_reviews"),
                    null)),
            Map.entry("V999_6__finance_cost_template_inputs.sql",new LegacyFinanceAudit("4a2531b6e1c6ed26d875c5706e340f1716dfb23aa9c285dbca18a809ffbbcb18",
                    List.of("create trigger trg_audit_finance_copper_template_inputs after insert or update or delete on finance_copper_template_inputs for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_sales_cost_inputs after insert or update or delete on finance_sales_cost_inputs for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_plastic_template_inputs after insert or update or delete on finance_plastic_template_inputs for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_material_order_references after insert or update or delete on finance_material_order_references for each row execute function fn_audit();"),
                    List.of("finance_copper_template_inputs","finance_sales_cost_inputs","finance_plastic_template_inputs","finance_material_order_references"),
                    null)),
            Map.entry("V999_7__finance_asset_template_facts.sql",new LegacyFinanceAudit("ab59e77ae658abf4960370270bddb7a1a036e81c4b8050d9c2f08770d192cc42",
                    List.of("create trigger trg_audit_finance_asset_template_metadata after insert or update or delete on finance_asset_template_metadata for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_asset_opening_groups after insert or update or delete on finance_asset_opening_groups for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_asset_opening_members after insert or update or delete on finance_asset_opening_members for each row execute function fn_audit();",
                            "create trigger trg_audit_finance_asset_template_history after insert or update or delete on finance_asset_template_history for each row execute function fn_audit();"),
                    List.of("finance_asset_template_metadata","finance_asset_opening_groups","finance_asset_opening_members","finance_asset_template_history"),
                    null)));

    private static final Pattern LEGACY_SUBVERSION_AUDIT = Pattern.compile(
            "create trigger ([a-z_][a-z0-9_]*) after (?:insert(?: or update)?(?: or delete)?)"
                    + " on ([a-z_][a-z0-9_]*) for each row execute function (?:public\\.)?fn_audit\\(\\);");
    private static final String SUBVERSION_AUDIT_FORWARD =
            "V1059__financial_subversion_audit_policy_registration.sql";

    record ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                       String reason, String updateFn, String rowFn, boolean redacted) {
        ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                    String reason) {
            this(table, category, insertDelete, columns, reason, null, null, false);
        }

        ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                    String reason, String updateFn) {
            this(table, category, insertDelete, columns, reason, updateFn, null, false);
        }

        ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                    String reason, String updateFn, String rowFn) {
            this(table, category, insertDelete, columns, reason, updateFn, rowFn, false);
        }

        ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                    String reason, boolean redacted) {
            this(table, category, insertDelete, columns, reason, null, null, redacted);
        }
    }

    record NoneGroup(String key, String reason, Set<String> tables) {
    }

    /** FULL: 整行审计(INSERT/DELETE 存整行, UPDATE 只存变化键)。分组即理由, 分组内每张表同一理由。 */
    static final List<FullGroup> FULL = List.of(
            new FullGroup("stock_adoption_decisions", "data_change", false,
                    "V1108/V1109 同销售库存采用、公共现货认领命令、精确库存归属及正式计划交接决定保持原FULL审计，V1112只前向接入公共登记，不改历史或业务守卫",
                    Set.of("preplan_sales_stock_adoptions", "preplan_physical_stock_claim_commands",
                            "preplan_physical_stock_claim_allocations", "preplan_physical_stock_formalizations")),
            new FullGroup("physical_delivery_decisions", "data_change", false,
                    "V1049/V1056 原始BOM交付策略与原订单库存认领保留既定FULL审计，认领请求、事件和行事件按迁移的同一公共登记执行",
                    Set.of("goods_bom_delivery_rules", "sales_delivery_order_claims",
                            "sales_delivery_order_claim_requests", "sales_delivery_order_claim_events",
                            "sales_delivery_order_claim_row_events")),
            new FullGroup("employee_identity_aliases", "authorization", false,
                    "V937 经人工证据核实的员工身份合并关系决定跨档案历史的查询范围；身份授权决定须完整审计，不能因只追加而豁免",
                    Set.of("employee_identity_aliases")),
            new FullGroup("employee_identity_physical_merges", "authorization", false,
                    "V964/965 已核验同人永久合并、退休账号与 Worker 映射和精确工号释放决定身份及编号归属；证书和原 actor 保留完整审计",
                    Set.of("employee_identity_merges", "employee_legacy_identity_aliases",
                            "employee_identity_user_tombstones", "employee_code_reuse_releases")),
            new FullGroup("employee_identity_reviews", "authorization", true,
                    "V964 同名不同人和历史标识重新核验由 owner 留证；证件和手机 HMAC 不复制到通用审计载荷",
                    Set.of("employee_identity_review_certificates")),
            new FullGroup("employee_code_reuse_claims", "data_change", false,
                    "V965 已释放工号只能由新员工 UUID 原子领取；永久领取证据保留实际 actor、数据集和事务审计",
                    Set.of("employee_code_reuse_claims")),
            new FullGroup("document_unapprovals", "data_change", false,
                    "反审的原审核与后续草稿关系及原因是永久审计事实", Set.of("document_unapprovals")),
            new FullGroup("permission_templates", "authorization", false,
                    "V894 权限模板是超管保存的授权快照；增改与软删除完整审计，应用到账号仍由独立授权流程决定",
                    Set.of("permission_templates", "permission_template_applies",
                            "user_permission_template_bindings", "department_permission_template_bindings")),
            new FullGroup("company_file_acl", "authorization", false,
                    "公司资料目录的用户和部门允许与拒绝规则是人工授权决定，必须逐行审计",
                    Set.of("company_file_acl")),
            new FullGroup("company_file_nodes", "data_change", false,
                    "公司资料身份、目录层级、密码保护与回收状态需留痕，密码哈希和自由说明由统一脱敏函数移除",
                    Set.of("company_file_nodes")),
            new FullGroup("authorization", "authorization", false,
                    "账号、权限点、授权覆盖与数据范围: 谁能做什么的唯一事实, 每次变化都要能还原前后值(角色四表已随 V677 删除)",
                    Set.of(
                        // V815：管理员按人限额/停用属于授权决定，FULL/authorization 保留前后值。
                        "ai_user_limits",
                        "client_visibility_grants", "client_co_owners", "department_permissions",
                        "manager_permission_delegations",
                        "organization_permission_leader_assignments",
                        "permission_surface_permissions", "permission_surfaces", "permissions",
                        "user_data_scopes", "user_permission_overrides", "users")),
            new FullGroup("system", "system", false,
                    "系统设置与全局配置: 改动影响全平台运行口径",
                    Set.of(
                        "business_identifier_namespaces", "expense_claim_settings", "data_lifecycle_policies",
                        "system_master_category_registry", "business_record_retention_registry",
                        "system_posting_style_roles", "system_settings",
                        "unit_measurement_profiles")),
            new FullGroup("master", "data_change", false,
                    "基础资料主档: 人工维护, 被所有单据引用",
                    Set.of(
                        "accounts", "business_column_definitions", "business_column_deletions", "platform_column_definition_deletions",
                        "sales_alias_document_evidence", "client_categories", "client_ship_addresses", "clients",
                        "colors", "currencies", "finance_payment_methods", "goods",
                        "goods_market_reference_bindings",
                        "goods_bom_items", "goods_cost_sheets", "goods_cost_snapshots", "goods_cost_templates",
                        "goods_cost_imports", "goods_cost_import_mappings",
                        "goods_weight_profiles",
                        "goods_import_batches", "goods_import_creations",
                        "goods_operation_history", "goods_operation_history_rows", "goods_operation_history_events",
                        "master_operation_history", "master_operation_history_rows", "master_operation_history_events",
                        "master_code_change_batches", "material_categories", "mould_categories",
                        "moulds", "party_activity_records",
                        "party_addresses", "party_contact_methods", "payment_styles",
                        "settlement_methods", "supplier_categories", "suppliers", "units",
                        "warehouse_keepers", "warehouses",
                        // V740 (ADR-131): 车间整批领料设置、机台与容器、产品认料
                        "workshop_material_settings", "workshop_machines", "workshop_machine_containers",
                        "goods_periodic_material_choices",
                        "goods_material_identity_evidence",
                        // V802 (ADR-147): 车间内料仓开通记录(开通人、来源仓、版本)
                        "workshop_bins")),
            new FullGroup("count_decisions_and_lineage", "data_change", false,
                    "V766/V768 的盘点申请、逐行计数、处理事件和过账关联是可追溯的业务决定，建表迁移明确 FULL；不以队列或派生名义免审",
                    Set.of("stock_count_requests", "stock_count_request_lines", "stock_count_request_events",
                            "workshop_material_count_adjustment_postings")),
            new FullGroup("source_and_field_versions", "data_change", false,
                    "正式 AI 原件绑定和扩展字段版本保留单据与操作者谱系；V773/V779 明确 FULL，字段原载荷由原生权限历史读取，通用审计投影屏蔽敏感载荷",
                    Set.of("ai_input_original_bindings", "platform_record_field_versions")),
            new FullGroup("org_hr", "data_change", false,
                    "组织、人事与访客资料: 人工维护的敏感资料, 由脱敏函数去掉证件/联系方式/自由文本后整行审计",
                    Set.of(
                        "attachments", "departments", "emergency_contacts",
                        "employee_compensation", "employee_contracts", "employee_credentials",
                        "employee_data_handover_scopes", "employee_data_handovers",
                        "employee_education", "employee_phones", "employee_secondary_departments",
                        "employee_sensitive", "employee_vehicles", "employees",
                        "employment_history", "positions", "profile_change_requests",
                        "rd_task_forwarders", "rd_tasks", "suggestion_replies", "suggestions",
                        "visitor_accounts", "visitor_applications", "visitor_approval_steps",
                        "website_inquiries")),
            new FullGroup("payroll", "data_change", true,
                    "工资与报销: 额外去掉金额与姓名快照后整行审计",
                    Set.of(
                        "expense_claim_items", "expense_claims", "payroll_batches",
                        "payroll_items", "payroll_slips", "payroll_variable_inputs")),
            new FullGroup("sales_docs", "data_change", false,
                    "销售单据头与明细: 人工录入并审核的业务单据",
                    Set.of(
                        "sales_order_cost_items", "sales_order_items", "sales_orders",
                        "sales_other_shipment_items", "sales_other_shipments", "sales_quote_items",
                        "sales_quotes", "sales_return_items", "sales_return_quality_items",
                        "sales_returns", "sales_shipment_items", "sales_shipments")),
            new FullGroup("purchase_docs", "data_change", false,
                    "采购单据、财务审批案与供应商结算: 人工录入并审核的业务单据",
                    Set.of(
                        "procurement_arrival_exceptions", "procurement_iqc_rejection_cases",
                        "procurement_order_approval_cases", "purchase_order_items",
                        "purchase_orders", "purchase_receipt_items", "purchase_receipts",
                        "purchase_request_items", "purchase_requests", "purchase_return_items",
                        "purchase_returns", "supplier_claim_cash_receipts",
                        "supplier_claim_receivables", "supplier_open_item_offsets",
                        "supplier_return_tasks", "supplier_settlement_batch_lines",
                        "supplier_settlement_batches")),
            new FullGroup("subcontract_docs", "data_change", false,
                    "委外单据头与明细: 人工录入并审核的业务单据",
                    Set.of(
                        "subcontract_application_items", "subcontract_applications",
                        "subcontract_inquiries", "subcontract_inquiry_items",
                        "subcontract_loss_case_lines", "subcontract_loss_cases",
                        "subcontract_loss_resolutions", "subcontract_material_issue_items",
                        "subcontract_material_issues", "subcontract_material_plan_items",
                        "subcontract_material_plans", "subcontract_material_return_items",
                        "subcontract_material_returns", "subcontract_order_cost_items",
                        "subcontract_order_items", "subcontract_orders",
                        "subcontract_receipt_items", "subcontract_receipts",
                        "subcontract_return_items", "subcontract_returns",
                        "subcontract_short_delivery_cases", "subcontract_waste_items",
                        "subcontract_wastes")),
            new FullGroup("goods_code_evidence", "data_change", false,
                    "货品编号生命周期、使用与回用证据：保留原身份和业务使用事实",
                    Set.of("goods_code_lifecycles", "goods_code_usage_facts", "goods_code_reuse_releases")),
            new FullGroup("stock_docs", "data_change", false,
                    "库存单据、预留与调整申请: 人工录入并审核的业务单据",
                    Set.of(
                        "stock_balance_adjustment_requests", "stock_document_items",
                        "stock_documents", "stock_reservations", "stock_draw_issue_batches", "subcontract_selected_outbound_commands", "subcontract_selected_outbound_items")),
            new FullGroup("production_docs", "data_change", false,
                    "生产计划、日报、执行段、退料、点收、质检与直送单据: 人工录入并审核的业务单据",
                    Set.of(
                        "production_overproduction_rate_requests", "production_actual_output_supplement_requests",
                        // V823：本批超限处置的状态、版本与关联决定保留整行前后值。
                        "production_over_limit_dispositions",
                        "production_material_increment_requests", "production_material_discovery_requests",
                        "production_draw_issue_batches",
                        "preplan_aggregate_batches",
                        "production_daily_report_items", "production_daily_report_material_usages",
                        "production_daily_report_workers", "production_daily_reports",
                        "production_execution_segments",
                        "production_finished_arrival_registration_items",
                        "production_finished_arrival_registrations",
                        "production_finished_in_confirmation_items",
                        "production_finished_in_confirmations",
                        "production_fqc_inspection_sheet_items",
                        "production_fqc_inspection_sheets", "production_fqc_inspections",
                        "production_material_analysis_borrows",
                        "production_material_return_request_items",
                        "production_material_return_requests", "production_plan_items",
                        "production_plans", "production_workshop_direct_transfer_items",
                        "production_workshop_direct_transfers")),
            new FullGroup("workshop_material", "data_change", false,
                    "车间内料仓的领料/退回单、进出过账、期间、盘点与结算, 以及段的期间料行与换料 (ADR-131): "
                            + "人录入并确认的业务事实, 每笔进出、每次更正与撤销都要能还原前后值",
                    Set.of(
                        "production_execution_periodic_materials", "production_execution_material_changes",
                        "workshop_material_requisitions", "workshop_material_requisition_lines",
                        "workshop_material_stock_documents", "workshop_material_requisition_postings",
                        "workshop_material_other_issues", "workshop_material_periods",
                        "workshop_material_counts", "workshop_material_count_lines",
                        "workshop_material_period_lines", "workshop_material_count_postings",
                        "workshop_material_period_closes", "workshop_material_close_materials",
                        "workshop_material_close_allocations")),
            new FullGroup("application_workflows", "data_change", false,
                    "V1001/V1002 行政申请工作流与部门审批替代策略是人工发起、推进和复核的决定："
                            + "申请、提交轮次与事件整行审计，策略变更保留前后值",
                    Set.of("business_applications", "business_application_events",
                            "business_application_submissions", "department_approval_policies")),
            new FullGroup("finance_docs", "data_change", false,
                    "财务单据、凭证、往来台账与资产: 人工录入并审核的财务事实；报表确认和初始确认撤销保留可变决策前后值",
                    Set.of(
                        "ar_ap_ledger", "customer_open_item_offset_batches", "finance_report_line_bindings",
                        "finance_report_line_confirmations", "finance_asset_recognition_reversals",
                        "customer_open_item_offsets", "deferred_expenses",
                        "expense_claim_invoices", "finance_asset_accounting_periods",
                        "finance_asset_books", "finance_asset_categories",
                        "finance_asset_posting_lines", "finance_asset_posting_runs",
                        "finance_bank_transfer_lines", "finance_bank_transfers",
                        "finance_check_register", "finance_deferral_schedule_lines",
                        "finance_deferral_schedule_versions", "finance_expense_items",
                        "finance_expenses", "finance_other_income_items", "finance_other_incomes",
                        "finance_payment_lines", "finance_payments", "finance_receipt_lines",
                        "finance_receipt_source_allocations", "finance_receipts",
                        "finance_reconciliations", "fixed_assets", "gl_entries", "gl_vouchers",
                        "inventory_cost_gl_policy", "inventory_cost_gl_periods", "inventory_cost_gl_period_choices",
                        // V1004/V1007/V1023 财务复刻批次：报表档案与人工复核、供应商预付
                        // 生命周期、单据级应付费用调整；V1042 已按公共入口前向登记 FULL。
                        "finance_statement_profiles", "finance_statement_document_reviews",
                        "finance_supplier_advances", "finance_supplier_advance_parts",
                        "finance_supplier_advance_applications", "finance_supplier_advance_refunds",
                        "finance_payable_statement_adjustments", "finance_payable_statement_adjustment_lines")));

    /** COLUMN_SCOPED: 只审计人为决定的列; 派生列的变化不留行审计。 */
    static final List<ScopedTable> COLUMN_SCOPED = List.of(
            new ScopedTable("stock_monthly_summaries", "data_change", true,
                    List.of("last_rebuilt_at"),
                    "V949 可重建库存月汇总仅记录重建戳，不复制每笔库存投影数量变化"),
            new ScopedTable("stock_monthly_verification_state", "data_change", true,
                    List.of("last_verified_goods", "last_run_at", "last_chunk_rows", "last_drift_count", "last_error"),
                    "V949 分块校验进度与漂移结果是独立运行证据，仅保留明确列清单"),
            new ScopedTable("party_monthly_summaries", "data_change", true,
                    List.of("net_original", "posted_local_sum", "settled_local_sum", "net_local", "event_count", "null_original_count"),
                    "V950 往来月汇总按已登记的有限金额及计数列留核对证据，权威原始应收应付流水仍独立保留"),
            new ScopedTable("party_month_dirty", "data_change", true, List.of("touched_at"),
                    "V950 月汇总重算脏键只记录触达时间，不扩大到来源流水或业务原文"),
            new ScopedTable("business_archive_eligibility", "data_change", true,
                    List.of("eligible", "blocked_reasons", "final_settled_on", "evaluated_at"),
                    "V955 归档准入判定只记录有限结论与核验时点，不复制完整归档内容"),
            new ScopedTable("report_export_jobs", "data_change", true,
                    List.of("status", "snapshot_at", "snapshot_identity", "finished_at", "artifact_sha256", "error_message"),
                    "V938 永久导出请求身份独立保留，审计仅记录作业状态与发布摘要，不复制私有筛选或文件原文；原件删除守卫保持"),
            new ScopedTable("stock_measurement_holds", "data_change", true,
                    List.of("released_at", "verified_unit_id", "verified_by", "evidence_reference", "evidence_sha256", "resolution_note"),
                    "V930: 原数量/金额/重量快照不可改，但原计量依据的一次真实核验会更新六列，不能归只追加或NONE；"
                            + "实际新capture留最小身份，resolution只留变化；依据引用/说明仅记变化列名，数量金额重量和原文不复制",
                    "public.fn_audit_stock_measurement_hold_columns()", "public.fn_audit_stock_measurement_hold_columns()"),
            new ScopedTable("platform_branding", "system", false,
                    List.of("company_name", "company_aliases", "platform_name", "tagline", "primary_color", "secondary_color", "login_notice",
                            "support_phone", "support_email", "website", "logo_sha256", "updated_by"),
                    "V839: 公司平台品牌是人工系统决定；只审公开字段与 Logo 摘要，二进制图片不复制到审计；单行种子不挂新增/删除审计"),
            new ScopedTable("production_material_analyses", "data_change", true,
                    List.of("status", "cancelled_by", "cancelled_at", "cancellation_reason", "is_deleted", "deleted_at", "warehouse_id", "participating_warehouse_ids", "maker_id"),
                    "物料分析表头: 只记新建/删除与状态、取消、仓库、制单人这些人为决定, 版本号和指纹每次刷新都会变, 不记"),
            new ScopedTable("production_material_analysis_materials", "data_change", false,
                    List.of("confirmed_route", "route_reason", "route_confirmed_by"),
                    "物料分析物料行是每次刷新重算的投影: 只记人工确认路线与理由, 需求/可用/缺口等派生数量不记;"
                            + "V830 起 UPDATE 审计走窄投影函数(金样等值测试钉死与通用 fn_audit 逐字段一致)",
                    "public.fn_audit_route_columns()"),
            new ScopedTable("production_material_analysis_items", "data_change", false,
                    List.of("requested_qty", "delivery_date", "line_priority", "source_reason", "is_deleted"),
                    "物料分析来源行: 只记人工改的需求数量、交期、优先级、原因和删除, 就绪量等派生数量不记"),
            new ScopedTable("preplan_material_reallocations", "data_change", false,
                    List.of("status", "closed_by", "closed_at", "close_reason"),
                    "物料改挪记录: 新建时行内已带发起人与原因, 之后会被人工撤回/取消、随优先履约推进状态: "
                            + "只记状态与关闭人、关闭时间、关闭原因"),
            new ScopedTable("website_management_settings", "system", false,
                    List.of("version", "display_name", "public_origin", "enabled"),
                    "Website bridge public configuration decisions; secrets are environment-only and never stored or returned"),
            new ScopedTable("sms_gateway_settings", "system", false,
                    List.of("mode", "provider", "endpoint", "sign_name", "template_code", "version"),
                    "V867 SMS runtime settings: only public decisions and revision; neither encrypted credential, hint nor INSERT/DELETE snapshots enter audit"),
            new ScopedTable("ai_providers", "system", false,
                    List.of("name", "preset", "region", "protocol", "base_url", "model", "json_mode",
                            "thinking_control", "send_temperature", "supports_vision", "max_output_tokens",
                            "timeout_seconds", "enabled", "is_default",
                            "billing_mode", "billing_currency", "billing_input_per_million",
                            "billing_output_per_million", "billing_model"),
                    "AI 服务商配置(V742, ADR-133): 只记超管改的非密钥列; 不挂新增/删除触发器(整行会带上密钥密文), "
                            + "新建、删除、换密钥、设为默认由 AuditService 显式事件记录, 密文与尾号从不进审计"),
            new ScopedTable("platform_column_definitions", "data_change", true,
                    List.of("scope", "owner_user_id", "value_type", "price_protected"),
                    "V779: 不可变定义只记范围、所有者、值类型和价格保护；名称/公式与值原载荷不进入通用审计，使用次数不是业务决定"),
            new ScopedTable("goods_weight_observations", "data_change", false,
                    List.of("excluded_reason"),
                    "称重观测(V743/ADR-135): 插入由仓库采集自动产生, 行内带称重人与来源; 红冲标记是系统随单据撤回写的; "
                            + "只记人工排除/恢复这一个人为决定"),
            // ===== 2026-11 财务复刻/精度批次(V1004-V1040): 定位线索列清单, 不复制金额与业务原文 =====
            new ScopedTable("finance_material_contexts", "data_change", true,
                    List.of("id","auxiliary_id","account_code","accounting_currency_id","goods_id","color_id",
                            "amount_basis","original_currency_id","row_version","active","created_by","created_at"),
                    "V1005 物料对账单上下文由对账请求维护，审计只留身份、科目/币种绑定与版本等登记列"),
            new ScopedTable("finance_material_evidence", "data_change", true,
                    List.of("id","context_id","kind","resource_key","status","row_version","current_approved",
                            "source_fingerprint","submitted_by","submitted_at","approved_by","approved_at",
                            "created_by","created_at","updated_at"),
                    "V1005 对账单证据链是请求产物，只审计状态、指纹与提交/审批人等定位列"),
            new ScopedTable("finance_material_operations", "data_change", true,
                    List.of("request_id","actor_id","fingerprint","created_at"),
                    "V1005 对账单操作流水只留请求、操作者与指纹定位"),
            new ScopedTable("finance_native_posting_configurations", "data_change", true,
                    List.of("id","request_id","role_key","configuration_version","status","created_by","approved_by"),
                    "V1009 原生记账配置按登记列留角色键、版本与状态"),
            new ScopedTable("finance_native_debt_accounts", "data_change", true,
                    List.of("ledger_id","source_fingerprint","evidence_kind","created_by"),
                    "V1009 原生往来科目定位按登记列留账目、证据类型与创建人"),
            new ScopedTable("finance_native_cash_debt_parts", "data_change", true,
                    List.of("kind","cash_id","source_line_id","ledger_id","source_fingerprint","created_by"),
                    "V1009 资金-往来对应部件是不可变定位行，只留登记列"),
            new ScopedTable("finance_native_cash_accounts", "data_change", true,
                    List.of("kind","cash_id","created_by"),
                    "V1009 资金账户定位按登记列留类型与身份"),
            new ScopedTable("finance_native_supplier_offset_journals", "data_change", true,
                    List.of("offset_id","voucher_id","reversal_voucher_id","created_by"),
                    "V1009 供应商抵销记账线索按登记列留抵销与凭证定位"),
            new ScopedTable("finance_native_customer_offset_accounts", "data_change", true,
                    List.of("offset_id","created_by"),
                    "V1009 客户抵销科目定位按登记列留抵销身份"),
            new ScopedTable("finance_native_debt_entry_refs", "data_change", true,
                    List.of("ledger_id","entry_id","voucher_id","created_by"),
                    "V1009 冻结的分录引用按登记列留账目、分录与凭证定位"),
            new ScopedTable("finance_native_debt_correspondence_reviews", "data_change", true,
                    List.of("id","request_id","ledger_id","entry_id","source_fingerprint","status",
                            "created_by","approved_by"),
                    "V1009 原生记账对应复核按登记列留状态与审批人"),
            new ScopedTable("finance_native_legacy_opening_reviews", "data_change", true,
                    List.of("id","request_id","status","created_by","approved_by","reversed_by"),
                    "V1018 已核旧期初对应复核按登记列留状态与审批/红字人"),
            new ScopedTable("finance_native_legacy_opening_targets", "data_change", true,
                    List.of("id","review_id","ledger_id","legacy_proof_id","legacy_fingerprint"),
                    "V1018 旧期初对应目标按登记列留账目与证据定位"),
            new ScopedTable("finance_native_legacy_opening_parts", "data_change", true,
                    List.of("id","review_id","ledger_id","entry_id","allocation_no","source_fingerprint"),
                    "V1018 旧期初对应分摊按登记列留分摊号与来源指纹"),
            new ScopedTable("finance_classification_corrections", "data_change", true,
                    List.of("id","request_id","created_by","direction","party_id","currency_id",
                            "graph_fingerprint","command_hash","status","created_at"),
                    "V1020 全图分类更正命令按登记列留请求、方向与指纹"),
            new ScopedTable("finance_classification_correction_nodes", "data_change", true,
                    List.of("correction_id","kind","object_id","old_batch_id","new_batch_id"),
                    "V1020 更正节点是命令的组成部分，只留对象与前后批次定位"),
            new ScopedTable("finance_supplier_advance_target_classification_batches", "data_change", true,
                    List.of("id","application_id","revision","correction_id","target_classification_id",
                            "created_by","created_at"),
                    "V1020 预付目标分类批次按登记列留请求与修正关联"),
            new ScopedTable("finance_supplier_advance_target_classification_parts", "data_change", true,
                    List.of("batch_id","category"),
                    "V1020 预付目标分类明细只留批次与类别"),
            new ScopedTable("finance_classification_request_receipts", "data_change", true,
                    List.of("request_id","created_by","command_hash","status","correction_id","created_at"),
                    "V1020 分类更正请求回执按登记列留状态与命令哈希"),
            new ScopedTable("finance_statement_settlement_versions", "data_change", true,
                    List.of("review_id","root_review_id","based_review_id","based_source_fingerprint",
                            "effect_fingerprint","explicitly_no_deductions","created_by"),
                    "V1028 结算单原版本谱系只留复核链与指纹等登记列"),
            new ScopedTable("finance_subcontract_quantity_evidence", "data_change", true,
                    List.of("id","request_id","scope_key","statement_key","revision","supplier_id","date_from",
                            "date_to","purpose","evidence_type","source_kind","source_item_id",
                            "material_issue_item_id","goods_id","color_id","pcs_unit_id","status","enabled",
                            "apply_to_statement","submitted_by","reviewed_by"),
                    "V1027 委外对账单数量证据按登记列审计提交/复核与生效状态"),
            new ScopedTable("finance_subcontract_loss_policies", "data_change", true,
                    List.of("id","request_id","supplier_id","goods_id","color_id","unit_id","effective_from",
                            "effective_to","revision","status","enabled","submitted_by","reviewed_by"),
                    "V1022 委外损耗率政策按登记列审计人工提交/复核与生效期"),
            new ScopedTable("finance_payroll_accrual_lines", "data_change", true,
                    List.of("entry_id","batch_id","payroll_slip_id","employee_id","department_id",
                            "source_payroll_period","expense_style_id","amount_kind","source_payroll_item_id",
                            "deduction_allocation_id","created_by","created_at"),
                    "V1006 工资计提行按登记列留分配身份与来源；金额与工资源数据不入通用审计", true),
            new ScopedTable("goods_bom_material_cost_adoptions", "data_change", true,
                    List.of("id","goods_id","goods_version","source_action_id","actor_id","request_id",
                            "numeric_evidence_id","created_at"),
                    "V1034 货品 BOM 材料成本采纳按登记列留来源动作与证据定位"),
            new ScopedTable("goods_bom_periodic_quantity_adoptions", "data_change", true,
                    List.of("id","goods_id","bom_item_id","component_goods_id","source_action_id","actor_id",
                            "request_id","numeric_evidence_id","created_at"),
                    "V1034 货品周期数量采纳按登记列留来源动作与证据定位"),
            new ScopedTable("report_export_precision_resumes", "data_change", true,
                    List.of("request_id","job_id","actor_id","expected_attempt","created_at"),
                    "V1013 导出等待精度续算登记只留请求、作业、actor 与重试序号"),
            new ScopedTable("business_numeric_input_evidence", "data_change", true,
                    List.of("id","owner_kind","owner_id","source_row_id","field_key","owner_version",
                            "source_action_id","actor_id","request_id","fingerprint","created_at"),
                    "V1024 私有用数输入证据按登记列留身份与指纹，不复制业务原文"),
            new ScopedTable("finance_application_continuation_reviews", "data_change", true,
                    List.of("id","origin_id","original_application_id","actor_id","actor_employee_id",
                            "source_version","source_fingerprint","target_kind","target_business_kind",
                            "target_id","expires_at","created_at"),
                    "V1040 原申请接续复核按登记列留来源版本、指纹与目标定位"),
            new ScopedTable("finance_application_native_mappings", "data_change", true,
                    List.of("origin_id","review_id","original_application_id","original_kind","native_kind",
                            "native_id","native_business_kind","source_fingerprint","original_currency_id",
                            "amount_basis","actor_id","actor_employee_id","request_id","created_at"),
                    "V1040 原申请与原生单据映射按登记列留双向身份与金额基准"),
            new ScopedTable("finance_application_continued_originals", "data_change", true,
                    List.of("review_id","attachment_id","owner_type","owner_id","sha256"),
                    "V1040 接续保留原件只留复核、附件与摘要定位"),
            new ScopedTable("finance_native_application_payment_proofs", "data_change", true,
                    List.of("application_id","submission_round","payment_id","source_branch","amount_basis",
                            "source_fingerprint","actor_id","actor_employee_id","created_at"),
                    "V1040 原生申请付款证明是不可变来源事实，只按登记列留分支与指纹"),
            new ScopedTable("expense_claim_source_links", "data_change", true,
                    List.of("claim_id","application_kind","travel_application_source_kind",
                            "business_travel_application_id","finance_travel_application_id",
                            "created_by","updated_by"),
                    "V1036 报销原来源链接按登记列留申请与差旅关联及操作者"),
            new ScopedTable("finance_document_intake_operations", "data_change", true,
                    List.of("request_id","actor_id","family","source_document_id"),
                    "V1030 财务单据接入操作流水只留请求、操作者与单据定位"),
            // V1006/V1015 的策略由建表迁移以动态循环登记、V1042 按同一列清单显式复述，这里逐表锁定。
            new ScopedTable("finance_payroll_preparations", "data_change", true,
                    List.of("application_id","batch_id","source_fingerprint","instruction_fingerprint",
                            "prepared_by","prepared_at"),
                    "V1006 工资准备按登记列留申请、批次与指纹定位，工资源数据不入通用审计"),
            new ScopedTable("finance_payroll_accruals", "data_change", true,
                    List.of("batch_id","application_id","source_fingerprint","instruction_fingerprint","mode",
                            "voucher_id","wage_style_id","created_at","created_by"),
                    "V1006 工资计提按登记列留批次、模式与凭证定位"),
            new ScopedTable("finance_payroll_payment_attempts", "data_change", true,
                    List.of("id","request_id","application_id","batch_id","source_fingerprint",
                            "instruction_fingerprint","account_id","payment_date","fee_style_id",
                            "payment_voucher_id","non_cash_voucher_id","receipt_kind","source_claim_only",
                            "account_flow_id","state","paid_at","paid_by","confirmed_at","confirmed_by",
                            "reversal_voucher_id","reversed_at","reversed_by"),
                    "V1006 工资付款尝试按登记列留账户、状态与付款/确认/红字定位"),
            new ScopedTable("finance_payroll_payment_actions", "data_change", true,
                    List.of("request_id","application_id","payment_request_id","action","actor_id",
                            "fingerprint","created_at"),
                    "V1006 工资付款动作流水只留请求、动作与操作者定位"),
            new ScopedTable("finance_gl_settlement_scopes", "data_change", true,
                    List.of("id","style_id","account_code","auxiliary_id","auxiliary_role","party_id_snapshot",
                            "accounting_currency_id","original_currency_id","natural_direction"),
                    "V1006 总账清偿范围按登记列留科目、辅助与币种定位"),
            new ScopedTable("finance_gl_settlement_reservations", "data_change", true,
                    List.of("id","request_id","scope_id","owner_kind","owner_id","actor_id","as_of","mode",
                            "fingerprint","status","created_at","updated_at"),
                    "V1006 总账清偿预留按登记列留状态、指纹与所有者定位"),
            new ScopedTable("finance_gl_settlement_source_parts", "data_change", true,
                    List.of("reservation_id","entry_id","allocation_no"),
                    "V1006 清偿来源部件是不可变定位行"),
            new ScopedTable("finance_gl_settlement_clearings", "data_change", true,
                    List.of("reservation_id","line_no","entry_id","allocation_no","source_entry_id",
                            "source_allocation_no"),
                    "V1006 清偿核销行按登记列留分录与分摊定位"),
            new ScopedTable("finance_gl_settlement_reversals", "data_change", true,
                    List.of("reservation_id","line_no","entry_id","allocation_no","original_entry_id",
                            "original_allocation_no"),
                    "V1006 清偿红字行按登记列留原分录与分摊定位"),
            new ScopedTable("finance_gl_settlement_operations", "data_change", true,
                    List.of("request_id","actor_id","fingerprint","operation","created_at"),
                    "V1006 清偿操作流水只留请求、操作与结果定位"),
            new ScopedTable("finance_receipt_classification_batches", "data_change", true,
                    List.of("id","request_id","receipt_line_id","revision","source_classification_id",
                            "currency_id","created_by","created_at"),
                    "V1015 收款分类更正批次按登记列留请求、版本与来源分类"),
            new ScopedTable("finance_receipt_classification_parts", "data_change", true,
                    List.of("batch_id","category"),
                    "V1015 收款分类更正明细只留批次与类别"),
            new ScopedTable("finance_customer_offset_classification_batches", "data_change", true,
                    List.of("id","request_id","offset_id","revision","source_classification_id",
                            "target_classification_id","source_kind","created_by","created_at"),
                    "V1015 客户抵销分类更正批次按登记列留请求、版本与目标分类"),
            new ScopedTable("finance_customer_offset_classification_parts", "data_change", true,
                    List.of("batch_id","source_category","target_category"),
                    "V1015 客户抵销分类更正明细只留批次与前后类别"),
            new ScopedTable("finance_chart_imports", "data_change", true,
                    List.of("id","actor_id","sha256","applied_at","created_at","parent_import_id","review_request_id","cancelled_at"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_chart_codes", "data_change", true,
                    List.of("code","native_style_id","source_import_id","source_kind","classification","currency_id",
                            "row_version","mapping_fingerprint","updated_by"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_chart_manual_operations", "data_change", true,
                    List.of("request_id","actor_id","fingerprint","created_at"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_chart_code_styles", "data_change", true,
                    List.of("code","style_id","created_at","created_by"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_chart_owned_bindings", "data_change", true,
                    List.of("code","style_id","line_key"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_accounting_import_batches", "data_change", true,
                    List.of("id","actor_id","sha256","status","row_version","submitted_by",
                            "submitted_at","approved_by","approved_at","paired_import_id","created_at","kind","reversed_at","reversed_by"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_gl_voucher_evidence", "data_change", true,
                    List.of("voucher_id","import_batch_id","purpose","source_sha256","submitted_by","approved_by",
                            "approved_at","reversed_voucher_id"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_gl_entry_allocations", "data_change", true,
                    List.of("entry_id","allocation_no","account_code","currency_id","original_currency_id","auxiliary_id",
                            "auxiliary_role","party_id_snapshot","created_at","created_by","source_row"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_accounting_period_coverage", "data_change", true,
                    List.of("period","entries_revision","source_kind","import_batch_id","source_sha256","verified_by",
                            "verified_at"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_gl_auxiliary_opening_evidence", "data_change", true,
                    List.of("id","import_batch_id","account_code","auxiliary_id","currency_id","original_currency_id",
                            "effective_from","entry_id","auxiliary_role","party_id_snapshot","source_sha256","submitted_by",
                            "approved_by","approved_at","source_row"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_accounting_review_operations", "data_change", true,
                    List.of("request_id","actor_id","import_id","action","fingerprint","created_at"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_gl_opening_baselines", "data_change", true,
                    List.of("effective_from","import_batch_id","source_sha256","verified_by","verified_at"),
                    "V1059 原科目与会计来源保留身份、审批及指纹定位，私有原文与金额不进入通用审计"),
            new ScopedTable("finance_auxiliary_parties", "data_change", true,
                    List.of("id","row_version","created_at","created_by","updated_by",
                            "source_system","source_code","source_name"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_auxiliary_items", "data_change", true,
                    List.of("id","role","party_id","client_id","supplier_id","employee_id",
                            "financial_party_id","status","row_version","created_at","created_by","updated_by",
                            "source_system","source_code","source_name","source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_account_auxiliary_rules", "data_change", true,
                    List.of("account_code","required","allowed_roles","row_version","updated_by",
                            "source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_account_auxiliary_bindings", "data_change", true,
                    List.of("account_code","auxiliary_id","created_at","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_statement_source_reviews", "data_change", true,
                    List.of("id","actor_id","kind","currency_id","date_from","date_to",
                            "sha256","currency_mapping_fingerprint","created_at","directory_applied_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_sales_cost_inputs", "data_change", true,
                    List.of("period","client_id","channel","confirmed","row_version","updated_by",
                            "tax_rate","freight_local","exchange_rate","source_reference","client_name_snapshot","seller_name_snapshot","region_snapshot","director_snapshot"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_plastic_template_inputs", "data_change", true,
                    List.of("period_line_id","source_close_id","source_unit_id","template_row","confirmed","row_version",
                            "updated_by",
                            "weight_kg_per_unit","material_name","reject_return_qty","reject_issue_qty","reason","source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_material_order_references", "data_change", true,
                    List.of("requisition_id","confirmed","row_version","updated_by",
                            "order_no","source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_copper_template_inputs", "data_change", true,
                    List.of("source_line_id","supplier_id","goods_id","section_key","confirmed","row_version",
                            "updated_by",
                            "source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_template_sources", "data_change", true,
                    List.of("id","actor_id","template_key","period","sha256","source_selection"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_asset_template_metadata", "data_change", true,
                    List.of("id","object_type","object_id","valid_from","document_date","confirmed",
                            "row_version","created_at","created_by","updated_by",
                            "party_name","unit_specification","location_caption","category_caption","usage_caption","source_month","first_level_caption","second_level_caption","acceptance_caption","source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_asset_opening_groups", "data_change", true,
                    List.of("id","actor_id","source_import_id","source_voucher_id","as_of","source_voucher_ids",
                            "fingerprint","status","approved_by","approved_at","revoke_actor_id","revoke_approved_by",
                            "revoked_at","row_version","created_at",
                            "zero_balance_evidence","source_entry_snapshot","member_snapshot","reason","revoke_reason"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_asset_opening_members", "data_change", true,
                    List.of("group_id","object_type","object_id","source_row","source_sha256","cost_style_id",
                            "accumulated_style_id","active",
                            "source_sheet","original_amount","accumulated_amount","remaining_months","nominal_monthly_amount"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_asset_opening_entry_claims", "data_change", true,
                    List.of("entry_id","group_id"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_asset_template_history", "data_change", true,
                    List.of("id","group_id","object_type","object_id","period_from","period_to",
                            "source_import_id","source_row","source_column"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_sales_expense_groups", "data_change", true,
                    List.of("id","period","employee_id","channel","sales_confirmed","reviewed",
                            "sort_order","request_fingerprint","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_sales_expense_assignments", "data_change", true,
                    List.of("entry_id","period","source_fingerprint","request_fingerprint","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_expense_analysis_periods", "data_change", true,
                    List.of("period","policy_confirmed","locked","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_operating_report_notes", "data_change", true,
                    List.of("period","line_key","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_expense_note_imports", "data_change", true,
                    List.of("id","actor_id","period","sha256","applied_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_manufacturing_labor_splits", "data_change", true,
                    List.of("period","source_fingerprint","request_fingerprint","reviewed","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_procurement_ap_policy", "data_change", true,
                    List.of("singleton","enabled","effective_from","row_version","updated_by",
                            "source_reference"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_procurement_payable_routes", "data_change", true,
                    List.of("source_type","source_id","policy_version","approved_on","created_by","created_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_procurement_payable_candidates", "data_change", true,
                    List.of("id","source_type","source_id","commercial_date","accrual_date","due_date",
                            "supplier_id","currency_id","settlement_method_id","inventory_style_id","pending_style_id","pending_account_code",
                            "pending_accounting_currency_id","auxiliary_id","source_fingerprint","pending_voucher_id","pending_reversal_voucher_id","status",
                            "ledger_id","recognition_id","created_by","created_at","source_reversed_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_procurement_ap_recognitions", "data_change", true,
                    List.of("id","request_id","payload_hash","supplier_id","currency_id","effective_date",
                            "counterpart_confirmed_date","file_sha256","submitted_by","created_at","status","approved_by",
                            "approved_at","reversed_by","reversed_at",
                            "source_reference","counterpart_confirmed_by","file_provider","file_key","file_version","file_size","file_name","file_content_type","reverse_reason"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_procurement_ap_recognition_lines", "data_change", true,
                    List.of("recognition_id","candidate_id","ledger_id","voucher_id","reversal_voucher_id","source_fingerprint"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_settings", "authorization", true,
                    List.of("id","enabled","enabled_at","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_enable_periods", "authorization", true,
                    List.of("id","enabled_at","disabled_at","actor_id"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_role_bindings", "authorization", true,
                    List.of("id","role_key","department_id","employee_id","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_applications", "data_change", true,
                    List.of("id","application_no","kind","source_kind","source_id","status",
                            "current_step","submission_round","source_fingerprint","payroll_instruction_fingerprint","submitted_at","approved_at",
                            "approved_by","created_by","updated_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_nodes", "data_change", true,
                    List.of("application_id","submission_round","step_no","role_key","action","status",
                            "decided_by","decided_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_events", "data_change", true,
                    List.of("id","application_id","submission_round","event_type","step_no","actor_id",
                            "actor_employee_id","occurred_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_operations", "data_change", true,
                    List.of("request_id","application_id","actor_id","operation","payload_hash","created_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_application_executions", "data_change", true,
                    List.of("id","application_id","submission_round","request_id","doc_type","doc_id",
                            "state","paid_by","paid_at","confirmed_by","confirmed_at","reversed_by",
                            "reversed_at"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_expense_application_links", "data_change", true,
                    List.of("claim_id","kind","travel_application_id","application_id","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_supplier_settlement_dependencies", "data_change", true,
                    List.of("payment_line_id","offset_id","ledger_id","relation","created_at","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_open_item_classification_batches", "data_change", true,
                    List.of("id","request_id","ledger_id","revision","direction","party_id",
                            "currency_id","effective_from","fingerprint","created_at","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_open_item_classification_parts", "data_change", true,
                    List.of("batch_id","category"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_payment_classification_batches", "data_change", true,
                    List.of("id","request_id","payment_line_id","revision","source_classification_id","currency_id",
                            "fingerprint","created_at","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_payment_classification_parts", "data_change", true,
                    List.of("batch_id","category"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_supplier_offset_classification_batches", "data_change", true,
                    List.of("id","request_id","offset_id","revision","source_classification_id","target_classification_id",
                            "fingerprint","created_at","created_by"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("finance_supplier_offset_classification_parts", "data_change", true,
                    List.of("batch_id","source_category","target_category"),
                    "V1059 财务原件与人工决定保留身份、状态及操作者定位，金额、姓名和说明由原生权限入口读取"),
            new ScopedTable("sales_shipment_delivery_components", "data_change", true,
                    List.of("id","shipment_id","shipment_item_id","order_item_id","bom_path","bom_fingerprint",
                            "goods_id","color_id","unit_id","required_qty","required_operations","warehouse_id",
                            "stock_place","processing_completed_qty","processing_completed_by","processing_completed_at","movement_id","reversal_movement_id",
                            "revision"),
                    "V1051 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_processing_events", "data_change", true,
                    List.of("id","component_id","request_id","quantity","operation","actor_employee_id",
                            "occurred_at"),
                    "V1051 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_processing_actions", "data_change", true,
                    List.of("request_id","component_id","action_type","request_hash","actor_employee_id","resulting_version",
                            "occurred_at"),
                    "V1052 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_warehouse_actions", "data_change", true,
                    List.of("request_id","shipment_id","component_id","action_type","workshop_id","responsible_id",
                            "request_hash","actor_employee_id","occurred_at"),
                    "V1053 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_fulfillment_groups", "data_change", true,
                    List.of("id","shipment_item_id","shipment_id","order_item_id","order_qty","state",
                            "created_by","created_at","updated_at"),
                    "V1054 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_fulfillment_allocations", "data_change", true,
                    List.of("id","shipment_item_id","analysis_id","analysis_item_id","position","order_qty",
                            "created_by","created_at"),
                    "V1054 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_entitlement_handoffs", "data_change", true,
                    List.of("id","component_id","allocation_id","source_analysis_id","source_material_id","entitlement_analysis_id",
                            "entitlement_material_id","aggregate_alias_id","source_entitlement_event_id","source_reservation_id","target_reservation_id","release_event_id",
                            "quantity","created_by","created_at"),
                    "V1054 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_entitlement_restores", "data_change", true,
                    List.of("id","handoff_id","restore_event_id","reason","created_by","created_at"),
                    "V1054 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"),
            new ScopedTable("sales_delivery_fulfillment_events", "data_change", true,
                    List.of("id","allocation_id","event_type","order_qty","counter_event_id","created_by",
                            "created_at"),
                    "V1054 实际交付、加工与归属恢复按既定登记列保留数量、身份及动作，不改变迁移中的业务口径"));

    /** NONE: 不挂行级审计。分组即理由。 */
    static final List<NoneGroup> NONE = List.of(
            new NoneGroup("imported_document_registry",
                    "V1115 导入单据登记表是 V926/V933 权威来源判定的读取侧物化，可由 fn_refresh_imported_document_registry 按纯遍历全量重算；原单据由各自表审计，运行账号只读，不复制为第二份行审计",
                    Set.of("imported_document_registry")),
            new NoneGroup("summary_read_freshness",
                    "V1095 完整列表的域字典与事务变化标记仅维护读取新鲜度；不保存原单、业务内容或授权决定，业务事实仍由原表审计，不重复复制技术协调态",
                    Set.of("summary_read_domains", "summary_read_markers")),
            new NoneGroup("financial_source_coordination",
                    "V999 子版本财务来源的期间修订计数与结果回执属于技术协调态；原始证据和实际人工决定由各自入口及元数据审计保留",
                    Set.of("finance_gl_period_versions", "finance_cost_input_operations",
                            "finance_asset_template_operations")),
            new NoneGroup("finance_batch_entry_receipts",
                    "V991 按账号和幂等键保存原子钱流批次的请求摘要与既定回执；实际单据和钱流仍按各自业务审计，重试只读取原回执，不把协调结果复制成第二份行审计",
                    Set.of("finance_batch_entry_commands")),
            new NoneGroup("stock_claim_storage_projection",
                    "V993 预留在实际仓位的剩余量由不可变流转事件维护，可按原预留与事件重建；不是人工主档或第二份库存归属，调拨单和预留决定继续保留 FULL 审计",
                    Set.of("stock_reservation_storage_positions")),
            new NoneGroup("read_authorization_version_lineage",
                    "V939 服务端固定域与读取范围版本谱系；原授权及归属变更仍按权威源表审计，附属事务版本事件和域字典由不可变触发器永久保留，不复制为第二份通用行审计",
                    Set.of("read_scope_domains", "read_scope_change_events")),
            new NoneGroup("technical",
                    "技术元数据、计数器、凭证、登录会话运行态与迁移控制: 不是业务数据, 或含凭证不应被复制"
                            + "(auth_sessions/auth_step_up_states 是会话与再认证失败计数, 登录、登出、"
                            + "再认证成功/失败与会话吊销另有显式安全事件, V680)",
                    Set.of(
                        "audit_log", "audit_log_archive", "auth_sessions", "auth_step_up_states",
                        "authorization_state", "scheduled_task_runs",
                        "employee_identity_merge_installation", "employee_code_reuse_installation",
                        "business_document_sequences", "category_master_code_sequences",
                        "doc_number_sequences", "flyway_schema_history",
                        "legacy_migration_checkpoints", "legacy_migration_reconciliation_items",
                        "legacy_migration_rejects", "legacy_migration_run_files",
                        "legacy_migration_runs", "master_code_sequences", "password_history",
                        "production_product_no_sequences", "refresh_tokens",
                        "report_materialized_view_refresh_state", "visitor_refresh_tokens",
                        "visitor_sms_codes",
                        // V742 AI 调用技术记录: 只有用途/服务商/token/耗时, 不含提示词、回复与密钥。
                        "ai_call_logs",
                        // V815：按人按日用量计数由调用记录汇总，不复制统计变化为业务审计。
                        "ai_usage_daily")),
            new NoneGroup("retained_private_evidence",
                    "永久原件、私有 before-image 和清理授权是独立证据，保留原载荷/关联并由授权原生入口读取；通用行审计不再次复制密钥、原上传、值单元或历史证据",
                    Set.of("ai_input_originals", "ai_provider_history", "business_record_history", "business_record_identities",
                            "business_outbox_payload_history", "business_archive_packages",
                            "employee_identity_merge_payloads", "employee_identity_historical_claims", "employee_identity_legacy_roles",
                            "master_record_versions",
                            "notice_blessing_history",
                            "sales_quote_template_candidate_history", "platform_record_fields")),
            new NoneGroup("notice",
                    "通知投递与互动机制: 人工发布、确认、祝福已有显式业务事件",
                    Set.of(
                        "notice_acknowledgments", "notice_blessings",
                        "notice_celebration_subjects", "notice_user_states", "notices",
                        "suggestion_likes",
                        // V798(ADR-143) 委外可领料通知高水位: 投递后的重算写入, 决定是否再次提醒。
                        "subcontract_draw_notice_marks",
                        // V809(ADR-156) 委外申请可下单通知高水位: 同上。
                        "subcontract_application_kit_notice_marks",
                        // V814(ADR-165) 车间任务到货进展产能高水位: 同上。
                        "production_execution_segment_notice_state")),
            new NoneGroup("queue",
                    "队列、任务、认领、幂等命令与系统核对结果: 系统协调状态, 人的操作由请求级语义事件记录",
                    Set.of(
                        "attachment_object_outbox", "attachment_reconciliation_findings",
                        "attachment_upload_sessions", "business_outbox", "hr_task_claims",
                        "procurement_iqc_rejection_commands", "production_daily_report_commands",
                        "production_fqc_release_commands", "production_material_analysis_commands",
                        "production_planning_drafts", "production_planning_urges", "production_bom_learning_refresh_queue", "stock_value_jobs",
                        "stock_value_production_cost_dirty", "stock_value_production_cost_tasks",
                        "stock_value_tasks",
                        "task_claims", "warehouse_arrival_registration_commands",
                        "workshop_material_commands", "goods_cost_commands",
                        // AI 识别任务协调态；原上传独立永久保全，提交人及原生单据范围控制读取。
                        "ai_jobs",
                        // V805(ADR-150) AI 确认卡一次性提案: 提议/确认/取消/回执各写显式审计事件, 行本身是协调态。
                        "ai_chat_action_proposals",
                        // V810(ADR-160) 员工核对记录：密文列与统计，不入行级审计；操作由显式业务事件记录。
                        "employee_reconcile_plans", "employee_reconcile_plan_rows",
                        "employee_reconcile_plan_items", "employee_reconcile_applies",
                        "pii_key_rotation_runs")),
            new NoneGroup("reservation",
                    "编号终身预留、冲突证据与改号历史: 只追加, 行本身就是占用/改号记录",
                    Set.of(
                        "business_identifier_conflicts", "business_identifier_reservation_members",
                        "business_identifier_reservations", "business_prefix_reservation_members",
                        "business_prefix_reservations", "master_code_history",
                        "master_code_reservation_members", "master_code_reservations",
                        // Private one-shot plans stay in this immutable journal;
                        // employees and employment_history retain their FULL audit.
                        "employee_code_numbering_receipts")),
            new NoneGroup("preference",
                    "使用偏好与自动学习: 系统按使用习惯自动写入, 不是业务决定",
                    Set.of(
                        // V816：个人问法与服务端操作的复用记忆；实际执行已有业务审计，不复制私有问法。
                        "ai_chat_operation_memory",
                        "user_preferences", "warehouse_goods_place_preferences",
                        // V833(ADR-172) 个人通知弹窗开关: 界面偏好, 只抑制弹窗层,
                        // 通知投递与办结另有业务事实。
                        "notice_popup_preferences",
                        // V742 客户货品对照与客户文件版式: 保存单据后自动学习; 用户删除对照另写显式审计事件。
                        "client_goods_aliases", "sales_intake_layouts", "platform_column_usage",
                        "sales_document_learning_receipts", "sales_intake_layout_learning_evidence",
                        // V745: sanitized reusable workbooks stay out of audit JSON; adoption/export
                        // have explicit actor/document events and immutable template versions.
                        "sales_quote_template_candidates", "sales_quote_customer_templates",
                        "sales_quote_template_versions", "sales_quote_template_evidence")),
            new NoneGroup("cost_posting_evidence",
                    "不可变实际成本过账关联保留操作者、价值事件与凭证身份；价值账和请求级业务事件承载审计，不复制整行",
                    Set.of("inventory_cost_gl_links")),
            new NoneGroup("derived",
                    "派生投影与计算结果: 可由单据和流水重算, 每次重算整行复制只是噪声",
                    Set.of(
                        "website_bridge_status",
                        // V962: private HMAC claim/lock projection; original PII and alias decisions retain their own audit.
                        "employee_identity_document_claims",
                        "account_flow_monthly_summaries", "da_amortization_log",
                        // V739 / ADR-129：学习档案、样本与真实使用数量由台账重算。
                        "goods_bom_actual_usages", "goods_bom_learning_profiles", "production_bom_learning_samples",
                        "execution_segment_sales_allocations", "fa_depreciation_log",
                        "goods_weight_estimates",
                        "inbound_expectation_items", "inbound_expectations", "mrp_generations",
                        "preplan_analysis_stock_exact_pegs", "preplan_future_supply_transfers",
                        "preplan_make_entitlement_delegations",
                        "preplan_reallocation_make_supplements",
                        "preplan_supply_action_allocations", "preplan_supply_actions",
                        "procurement_inspection_items", "procurement_iqc_replacement_allocations",
                        "production_fqc_release_allocations",
                        "production_fqc_replenishment_attempts",
                        "production_fqc_replenishment_cycles",
                        "production_fqc_replenishment_supply_gaps",
                        "production_fqc_replenishment_tasks", "production_material_demands",
                        "production_material_make_receipt_allocations",
                        "production_material_peg_transfers",
                        "production_material_receipt_allocations",
                        "production_material_subcontract_peg_transfers",
                        "production_material_subcontract_receipt_allocations",
                        "production_material_supply_pegs",
                        "production_workshop_direct_source_allocations", "stock_balances",
                        "stock_value_edges", "stock_value_node_revisions", "stock_value_nodes",
                        "stock_value_pools", "stock_value_production_cost_objects",
                        "stock_value_production_cost_outputs",
                        "stock_value_production_cost_shares",
                        "subcontract_loss_fulfillment_allocations",
                        "subcontract_outbound_issue_reservation_allocations",
                        "subcontract_receipt_material_consumptions",
                        "workshop_material_close_theory_lines")),
            new NoneGroup("link",
                    "单据关联与下达包: 由下单/下达命令生成的链接, 命令本身已有语义事件",
                    Set.of(
                        "plan_draw_links", "plan_order_item_links",
                        "production_fqc_replenishment_analysis_links",
                        "production_fqc_replenishment_draw_links",
                        "production_material_analysis_plan_links",
                        "production_material_movement_links",
                        "production_planning_package_document_items",
                        "production_planning_package_documents", "production_planning_packages",
                        "purchase_order_item_sources", "subcontract_order_item_sources",
                        "subplan_links",
                        // V1007 预付申请与付款行/抵销的先后依赖由申请命令生成，关系本身是定位证据。
                        "finance_supplier_advance_dependencies",
                        // V1009 原生记账生成的资金-往来-分录链接；记账请求与凭证另有业务事实。
                        "finance_native_cash_debt_entry_links")),
            new NoneGroup("ledger",
                    "只追加的事件/流水/批次账: 行内带操作人与时间(子行经父行追溯), 行本身就是留痕",
                    Set.of(
                        // V993: immutable event rows retain reservation/document/transaction lineage;
                        // the source reservation and stock document retain their FULL business audit.
                        "stock_reservation_storage_events",
                        "website_inquiry_events",
                        "document_malware_scans",
                        "account_balance_adjustment_batches", "account_balance_adjustment_items",
                        "ar_ap_source_refs", "client_access_change_events",
                        "employee_offboarding_events", "expense_claim_events",
                        "finance_asset_approval_steps", "finance_asset_events",
                        "production_material_discovery_lines",
                        "preplan_future_supply_transfer_cancellations",
                        "preplan_make_public_claims", "preplan_make_public_claim_cancellations",
                        "preplan_aggregate_batch_events", "preplan_aggregate_material_aliases", "preplan_aggregate_direct_transfer_slices",
                        "preplan_public_supply_events",
                        "preplan_root_output_events", "preplan_stock_entitlement_events",
                        "procurement_arrival_exception_events", "procurement_inspection_events",
                        "procurement_iqc_consideration_reversals",
                        "procurement_iqc_consideration_review_approvals",
                        "procurement_iqc_credit_case_allocations",
                        "procurement_iqc_credit_documents", "procurement_iqc_credit_slices",
                        "procurement_iqc_funding_settlements", "procurement_iqc_funding_slices",
                        "procurement_iqc_quality_consideration_parts",
                        "procurement_iqc_rejection_events",
                        "procurement_iqc_stock_consideration_parts",
                        "procurement_iqc_stock_in_batch_items", "procurement_iqc_stock_in_batches",
                        "procurement_order_approval_events", "procurement_order_qty_change_logs",
                        "procurement_order_source_revision_allocations",
                        "procurement_order_source_revision_peg_changes",
                        "procurement_order_source_revisions",
                        "procurement_order_termination_sources",
                        "procurement_order_termination_peg_changes",
                        "purchase_request_qty_revisions",
                        "procurement_receipt_consideration_parts",
                        "production_daily_report_material_release_events",
                        "production_overproduction_rate_decisions", "production_actual_output_supplement_proofs",
                        // V823：决定行含操作者、时间、理由和请求指纹，自身是只追加账本。
                        "production_over_limit_decisions",
                        "production_material_increment_decisions",
                        "production_material_increment_reversals",
                        "production_actual_output_supplement_reversals", "production_actual_output_supplement_claims",
                        "production_daily_report_target_events",
                        "production_execution_segment_events",
                        "production_execution_segment_growth_events",
                        "production_execution_segment_splits",
                        "production_finished_arrival_registration_reversals",
                        "production_finished_in_confirm_batch_items",
                        "production_finished_in_confirm_batches",
                        "production_finished_in_confirmation_reversal_items",
                        "production_finished_in_confirmation_reversals",
                        "production_fqc_cancellation_events",
                        "production_fqc_contribution_adjustments",
                        "production_fqc_decision_events", "production_fqc_pass_all_batch_items",
                        "production_fqc_pass_all_batches",
                        // V803 (ADR-148): 品质整批决定命令与逐份决定事件同为只追加账本。
                        "production_fqc_lot_decision_commands",
                        "production_fqc_recovery_allocation_events",
                        "production_fqc_recovery_authorizations",
                        "production_fqc_recovery_cancellation_events",
                        "production_fqc_replenishment_cycle_cancellations",
                        "production_fqc_replenishment_ready_events",
                        "production_fqc_replenishment_ready_reversals",
                        "production_material_return_receiving_confirmations",
                        "production_material_return_request_cancellations",
                        "production_material_settlement_events",
                        "production_material_settlement_postings",
                        "production_material_stock_events", "production_material_stock_postings",
                        "production_workshop_custody_handoff_reversals",
                        "production_workshop_custody_reverse_preparations",
                        "production_workshop_direct_source_events",
                        "production_workshop_direct_transfer_reversals",
                        "production_workshop_material_custody_handoffs",
                        "production_workshop_material_custody_moves",
                        "production_workshop_material_custody_preparations",
                        "production_workshop_material_custody_reversals",
                        "production_workshop_material_return_slices",
                        "production_workshop_return_preplan_events", "sales_order_qty_change_logs",
                        "sales_order_revision_logs", "sales_quote_revision_logs",
                        // V978: immutable manager decisions retain actor, revision, reason and original snapshot.
                        "sales_order_manager_review_events",
                        "sales_return_disposition_events",
                        "sales_return_quality_events", "sales_shipment_finance_release_events",
                        "sales_shipment_submission_events", "sales_shipment_warehouse_events",
                        "stock_movements", "stock_value_acquisition_sources", "stock_value_events",
                        "stock_value_legacy_balance_case_events", "stock_value_openings",
                        "stock_value_position_transfers", "stock_value_postings",
                        "stock_value_production_cost_inputs",
                        "stock_value_production_cost_revisions", "stock_weight_adjustments",
                        "subcontract_component_stock_handoffs",
                        "subcontract_loss_events",
                        "subcontract_short_delivery_case_events",
                        "supplier_settlement_batch_events",
                        "warehouse_arrival_exception_stock_in_batch_items",
                        "warehouse_arrival_exception_stock_in_batches")),
            new NoneGroup("legacy",
                    "老系统导入的只读数据与迁移核对证据: 由导入对账脚本核对, 不经在线写路径",
                    Set.of(
                        "client_default_settlement_migration_issues", "legacy_departments",
                        "legacy_finance_import_sources",
                        "legacy_procurement_receipt_import_sources",
                        "legacy_quantity_counter_import_sources",
                        "legacy_production_plan_counter_import_sources",
                        "legacy_production_plan_counter_import_contexts",
                        "legacy_subcontract_order_import_sources",
                        "legacy_warehouse_workshop_links", "production_fqc_legacy_exemptions",
                        "production_plan_costs", "production_workshop_direct_legacy_anomalies",
                        "stock_value_legacy_balance_cases")),
            new NoneGroup("frozen_application_authority",
                    "V1040 冻结的旧申请来源快照与轮次权威是只读历史证据: 行内带来源指纹与捕获时间, "
                            + "接续复核与原生映射另有 COLUMN_SCOPED 审计, 通用行审计不再次复制快照原文",
                    Set.of("finance_application_legacy_sources",
                            "finance_application_legacy_round_authorities")));

    /**
     * 「ledger」组只收只追加的表: 应用代码与 V670 之后的迁移里不许出现对它们的 UPDATE, 下面逐条写明的
     * 一次性完成回填除外(带状态/空值守卫, 只发生一次, 人的决定在插入行里)。会被人工改状态的表不能放进
     * ledger, 应归 COLUMN_SCOPED 或 FULL(例如物料改挪记录)。
     */
    static final Map<String, String> LEDGER_WRITE_ONCE_STAMPS = Map.of(
            "employee_offboarding_events",
            "离职交接执行结束时 EXECUTING -> COMPLETED 回填一次结果摘要; 发起交接的人和原因在插入行里",
            "production_material_settlement_events",
            "日报审核时回填一次所属日报(仅 daily_report_id 为空时); 结算事件本身不变",
            "warehouse_arrival_exception_stock_in_batches",
            "同一条到货异常入库命令内 PENDING -> COMPLETED 回填一次结果; 发起人与请求在插入行里");
    private static final Pattern UPDATE_TARGET = Pattern.compile(
            "(?i)\\bUPDATE\\s+(?:ONLY\\s+)?(?:\"?public\"?\\s*\\.\\s*)?\"?([a-z_][a-z0-9_]*)\"?");

    static Map<String, String> fullTables() {
        Map<String, String> result = new LinkedHashMap<>();
        FULL.forEach(group -> group.tables().forEach(table -> result.put(table, group.category())));
        return result;
    }

    static Set<String> redactedFullTables() {
        return FULL.stream().filter(FullGroup::redacted)
                .flatMap(group -> group.tables().stream()).collect(Collectors.toSet());
    }

    static Map<String, ScopedTable> scopedTables() {
        Map<String, ScopedTable> result = new LinkedHashMap<>();
        COLUMN_SCOPED.forEach(scoped -> result.put(scoped.table(), scoped));
        return result;
    }

    static Set<String> noneTables() {
        return NONE.stream().flatMap(group -> group.tables().stream()).collect(Collectors.toSet());
    }

    @Test
    void everyListedEntryHasAReasonAndBelongsToExactlyOneList() {
        Map<String, List<String>> owners = new HashMap<>();
        FULL.forEach(group -> {
            assertFalse(group.reason().isBlank(), group.key() + " needs a reviewable reason");
            assertTrue(CATEGORIES.contains(group.category()), group.key() + " category");
            group.tables().forEach(table ->
                    owners.computeIfAbsent(table, ignored -> new ArrayList<>()).add("FULL/" + group.key()));
        });
        COLUMN_SCOPED.forEach(scoped -> {
            assertFalse(scoped.reason().isBlank(), scoped.table() + " needs a reviewable reason");
            assertFalse(scoped.columns().isEmpty(), scoped.table() + " must name its audited columns");
            assertTrue(CATEGORIES.contains(scoped.category()), scoped.table() + " category");
            owners.computeIfAbsent(scoped.table(), ignored -> new ArrayList<>()).add("COLUMN_SCOPED");
        });
        NONE.forEach(group -> {
            assertFalse(group.reason().isBlank(), group.key() + " needs a reviewable reason");
            group.tables().forEach(table ->
                    owners.computeIfAbsent(table, ignored -> new ArrayList<>()).add("NONE/" + group.key()));
        });
        List<String> duplicated = owners.entrySet().stream()
                .filter(entry -> entry.getValue().size() > 1)
                .map(entry -> entry.getKey() + "=" + entry.getValue())
                .sorted().toList();
        assertEquals(List.of(), duplicated, "A table belongs to exactly one audit list");
        assertTrue(noneTables().containsAll(Set.of("audit_log", "audit_log_archive")),
                "The audit sink never audits itself");
    }

    @Test
    void ledgerTablesAreAppendOnlyExceptTheDeclaredWriteOnceStamps() throws IOException {
        Set<String> ledger = NONE.stream().filter(group -> group.key().equals("ledger"))
                .findFirst().orElseThrow().tables();
        assertTrue(ledger.containsAll(LEDGER_WRITE_ONCE_STAMPS.keySet()),
                "write-once stamps are an exception inside the ledger group only");
        Map<String, Set<String>> updates = new java.util.TreeMap<>();
        try (Stream<Path> files = Files.walk(Path.of("src/main/java"))) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                Matcher update = UPDATE_TARGET.matcher(Files.readString(file, StandardCharsets.UTF_8));
                while (update.find()) {
                    String table = update.group(1).toLowerCase(Locale.ROOT);
                    if (ledger.contains(table)) {
                        updates.computeIfAbsent(table, ignored -> new TreeSet<>()).add(file.getFileName().toString());
                    }
                }
            }
        }
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            Matcher update = UPDATE_TARGET.matcher(stripSqlComments(migration.sql()));
            while (update.find()) {
                String table = update.group(1).toLowerCase(Locale.ROOT);
                if (ledger.contains(table)) {
                    updates.computeIfAbsent(table, ignored -> new TreeSet<>())
                            .add(migration.path().getFileName().toString());
                }
            }
        }
        Set<String> staleStamps = new TreeSet<>(LEDGER_WRITE_ONCE_STAMPS.keySet());
        staleStamps.removeAll(updates.keySet());
        assertEquals(Set.of(), staleStamps, "a declared write-once stamp that no longer exists must be removed");
        updates.keySet().removeAll(LEDGER_WRITE_ONCE_STAMPS.keySet());
        assertEquals(Map.of(), updates,
                "ledger 组的表被更新了: 改归 COLUMN_SCOPED/FULL, 或确属一次性完成回填时登记理由");
    }

    @Test
    void everyTableInTheMigratedSchemaIsClassified() throws IOException {
        Set<String> live = new TreeSet<>(liveTableVersions().keySet());
        live.addAll(CREATED_OUTSIDE_MIGRATIONS);
        Set<String> classified = new TreeSet<>(fullTables().keySet());
        classified.addAll(scopedTables().keySet());
        classified.addAll(noneTables());

        Set<String> unclassified = new TreeSet<>(live);
        unclassified.removeAll(classified);
        assertEquals(Set.of(), unclassified,
                "新建表必须归入 FULL / COLUMN_SCOPED / NONE 之一并写明理由"
                        + "(FULL/COLUMN_SCOPED 还要在建表迁移里调用 fn_audit_track_table)");
        Set<String> stale = new TreeSet<>(classified);
        stale.removeAll(live);
        assertEquals(Set.of(), stale, "Listed tables must exist in the migrated schema");
    }

    @Test
    void storageClaimAuditCorrectionIsForwardOnlyAndKeepsBusinessHistory() throws Exception {
        Path originalPath = MIGRATION_ROOT.resolve("V993__storage_transfer_preserves_inventory_claims.sql");
        assertEquals("048e369d416ec1bc4c6bb28aaa0a616dcced9057e7ce430876d7cffcb0d059ce",
                HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                        .digest(Files.readAllBytes(originalPath))),
                "Previously committed V993 source bytes must not change on existing databases");
        String original = Files.readString(originalPath, StandardCharsets.UTF_8);
        assertTrue(original.contains("fn_audit_track_table('stock_reservation_storage_events','FULL'"));
        assertTrue(original.contains("trg_stock_storage_history_immutable"));
        assertTrue(original.contains("trg_stock_storage_position_no_delete"));

        String forward = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V997__stock_storage_audit_policy_forward.sql"), StandardCharsets.UTF_8));
        Map<String, String> policies = new LinkedHashMap<>();
        Matcher registration = REGISTRATION.matcher(forward);
        while (registration.find()) {
            assertNull(policies.put(registration.group(1), registration.group(2)),
                    "Each reviewed storage policy must be registered exactly once");
        }
        assertEquals(Map.of("stock_reservation_storage_events", "NONE",
                "stock_reservation_storage_positions", "NONE"), policies);
        assertFalse(Pattern.compile("(?i)\\b(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE)\\b")
                .matcher(forward).find(), "The forward correction must not rewrite schema, facts or business guards");
        assertTrue(NONE.stream().filter(group -> group.key().equals("ledger"))
                .findFirst().orElseThrow().tables().contains("stock_reservation_storage_events"));
        assertTrue(NONE.stream().filter(group -> group.key().equals("stock_claim_storage_projection"))
                .findFirst().orElseThrow().tables().contains("stock_reservation_storage_positions"));
        assertTrue(noneTables().contains("finance_batch_entry_commands"));
    }

    @Test
    void colorRemarkAndPaymentStyleHistoryExtensionsDoNotIntroduceAuditPolicyTables() throws IOException {
        for (int version : List.of(901, 902)) {
            MigrationSource migration = migrations().stream().filter(source -> source.version() == version).findFirst().orElseThrow();
            assertFalse(CREATE_TABLE.matcher(stripSqlComments(migration.sql())).find(),
                    "V" + version + " extends existing master fields/routes without new tables");
        }
        assertEquals("data_change", fullTables().get("colors"));
        assertEquals("data_change", fullTables().get("payment_styles"));
    }

    @Test
    void policyBaselineAppliesExactlyTheDeclaredFullAndScopedLists() throws IOException {
        String sql = stripSqlComments(Files.readString(POLICY_BASELINE, StandardCharsets.UTF_8));
        Map<String, String> declaredFull = new LinkedHashMap<>();
        Set<String> declaredRedacted = new HashSet<>();
        Matcher full = FULL_CALL.matcher(sql);
        while (full.find()) {
            Matcher table = QUOTED.matcher(full.group(3));
            while (table.find()) {
                assertEquals(null, declaredFull.put(table.group(1), full.group(1)),
                        table.group(1) + " is applied twice");
                if (Boolean.parseBoolean(full.group(2))) {
                    declaredRedacted.add(table.group(1));
                }
            }
        }
        // 基线之后新建的 FULL 表由各自建表迁移调用 fn_audit_track_table 登记(见下一个用例), 不在 V670 里。
        Map<String, Integer> created = liveTableVersions();
        Map<String, String> baselineFull = new LinkedHashMap<>(fullTables());
        baselineFull.keySet().removeIf(t -> created.getOrDefault(t, 0) > POLICY_BASELINE_VERSION);
        Set<String> baselineRedacted = new HashSet<>(redactedFullTables());
        baselineRedacted.removeIf(t -> created.getOrDefault(t, 0) > POLICY_BASELINE_VERSION);
        // V670 之后被整表删除的(如 V677 删除的角色四表)在 V670 登记过, 但不再出现在清单里。
        declaredFull.keySet().removeIf(t -> !created.containsKey(t));
        declaredRedacted.removeIf(t -> !created.containsKey(t));
        assertEquals(baselineFull, declaredFull, "V670 FULL calls must equal the FULL list and categories");
        assertEquals(baselineRedacted, declaredRedacted, "Payroll-class redaction flags must match");

        Map<String, ScopedTable> declaredScoped = new LinkedHashMap<>();
        Matcher scoped = SCOPED_CALL.matcher(sql);
        while (scoped.find()) {
            List<String> columns = new ArrayList<>();
            Matcher column = QUOTED.matcher(scoped.group(4));
            while (column.find()) {
                columns.add(column.group(1));
            }
            ScopedTable expected = scopedTables().get(scoped.group(1));
            assertTrue(expected != null, scoped.group(1) + " is scoped in V670 but not listed");
            // 基线调用只承载类别/列清单/插入删除开关; 专用 UPDATE 函数(V830 窄投影)只能由
            // 基线之后的再登记引入, 这里取清单当前值, 由"基线之后登记"用例独立钉住迁移里真写了。
            declaredScoped.put(scoped.group(1), new ScopedTable(scoped.group(1), scoped.group(2),
                    Boolean.parseBoolean(scoped.group(5)), columns, expected.reason(), expected.updateFn(),
                    expected.rowFn(), Boolean.parseBoolean(scoped.group(3))));
        }
        // 基线之后新建的 COLUMN_SCOPED 表(如 V742 ai_providers)由各自建表迁移登记, 形状在下一个用例核对。
        // 基线之后新建的 COLUMN_SCOPED 表(如 V743 称重观测)由建表迁移登记, 形态见下一个用例。
        Map<String, ScopedTable> baselineScoped = new LinkedHashMap<>(scopedTables());
        baselineScoped.keySet().removeIf(t -> created.getOrDefault(t, 0) > POLICY_BASELINE_VERSION);
        assertEquals(baselineScoped, declaredScoped, "V670 COLUMN_SCOPED calls must equal the list");

        String normalized = sql.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
        assertTrue(normalized.contains("when (old.* is distinct from new.*)"),
                "FULL updates must skip no-op rows before calling the audit function");
        assertTrue(normalized.contains("current_setting('app.legacy_import', true) = 'on'"),
                "Offline legacy imports bypass row auditing");
        assertTrue(normalized.contains("drop function public.fn_audit_classify("),
                "Classification is computed once at write time, not by a database trigger");
        assertTrue(normalized.contains("'updated_at', 'updated_by', 'version', 'lock_version'")
                        && normalized.contains("'last_login_at'")
                        && normalized.contains("'quantity_unit_locked'"),
                "Volatile columns never produce an update audit row");
        assertTrue(normalized.contains("v_action := 'delete'"),
                "Soft deletes keep delete meaning");
        assertTrue(normalized.contains("app.audit_device_context")
                        && normalized.contains("device_profile_hash"),
                "Database audit rows keep the device correlation");
        assertTrue(normalized.contains("fn_audit_mask_account"),
                "Stored accounts are masked");
    }

    @Test
    void tablesCreatedAfterTheBaselineRegisterTheirPolicyInMigrations() throws IOException {
        Map<String, Integer> created = liveTableVersions();
        Map<String, String> registered = new HashMap<>();
        Map<String, ScopedTable> registeredScoped = new HashMap<>();
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            String sql = stripSqlComments(migration.sql());
            Matcher registration = REGISTRATION.matcher(sql);
            while (registration.find()) {
                registered.put(registration.group(1), registration.group(2));
            }
            registered.putAll(literalFullAuditLoopRegistrations(sql));
            Matcher scoped = SCOPED_CALL.matcher(sql);
            while (scoped.find()) {
                List<String> columns = new ArrayList<>();
                Matcher column = QUOTED.matcher(scoped.group(4));
                while (column.find()) {
                    columns.add(column.group(1));
                }
                ScopedTable expected = scopedTables().get(scoped.group(1));
                registeredScoped.put(scoped.group(1), new ScopedTable(scoped.group(1), scoped.group(2),
                        Boolean.parseBoolean(scoped.group(5)), columns,
                        expected == null ? "" : expected.reason(), scoped.group(6), scoped.group(7),
                        Boolean.parseBoolean(scoped.group(3))));
            }
        }
        // 基线之后新建的 COLUMN_SCOPED 表: 建表迁移里的类别、列清单与插入/删除开关必须与清单逐项一致。
        Map<String, ScopedTable> laterScoped = new LinkedHashMap<>(scopedTables());
        laterScoped.keySet().removeIf(t -> created.getOrDefault(t, 0) <= POLICY_BASELINE_VERSION);
        laterScoped.forEach((table, expected) -> assertEquals(expected, registeredScoped.get(table),
                table + " must register fn_audit_track_table('" + table + "', 'COLUMN_SCOPED', ...) exactly as listed"));
        List<String> missing = new ArrayList<>();
        created.forEach((table, version) -> {
            if (version <= POLICY_BASELINE_VERSION) {
                return;
            }
            String expected = fullTables().containsKey(table) ? "FULL"
                    : scopedTables().containsKey(table) ? "COLUMN_SCOPED" : "NONE";
            // NONE needs no registration when a new table starts without audit
            // triggers. An explicit later registration must still agree with
            // the independent policy; do not silently accept FULL on a ledger.
            String actual = registered.get(table);
            if ((!"NONE".equals(expected) || actual != null) && !expected.equals(actual)) {
                missing.add(table + "@V" + version + " needs fn_audit_track_table('" + table + "', '"
                        + expected + "', ...)");
            }
        });
        assertEquals(List.of(), missing);

        // 基线之后新建的 COLUMN_SCOPED 表: 迁移里的列清单、类别与是否挂新增/删除触发器必须与清单逐项一致
        // (例如 V742 ai_providers 不挂新增/删除触发器, 否则整行带着密钥密文进审计)。
        Map<String, ScopedTable> declaredScoped = new LinkedHashMap<>();
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            Matcher scoped = SCOPED_CALL.matcher(stripSqlComments(migration.sql()));
            while (scoped.find()) {
                if (DROPPED_TRACKED_TABLES.contains(scoped.group(1))) {
                    // 历史登记 (V873/V874); 表本体已由 V970 删除, 不进当前三清单。
                    continue;
                }
                ScopedTable expected = scopedTables().get(scoped.group(1));
                assertTrue(expected != null, scoped.group(1) + " is scoped in "
                        + migration.path().getFileName() + " but not listed");
                List<String> columns = new ArrayList<>();
                Matcher column = QUOTED.matcher(scoped.group(4));
                while (column.find()) {
                    columns.add(column.group(1));
                }
                declaredScoped.put(scoped.group(1), new ScopedTable(scoped.group(1), scoped.group(2),
                        Boolean.parseBoolean(scoped.group(5)), columns, expected.reason(), scoped.group(6), scoped.group(7),
                        Boolean.parseBoolean(scoped.group(3))));
            }
        }
        Map<String, ScopedTable> listed = new LinkedHashMap<>(scopedTables());
        listed.keySet().retainAll(declaredScoped.keySet());
        assertEquals(listed, declaredScoped,
                "post-baseline COLUMN_SCOPED registrations must equal the list (columns, category, insert/delete)");
        Set<String> scopedAfterBaseline = new TreeSet<>(scopedTables().keySet());
        scopedAfterBaseline.removeIf(t -> created.getOrDefault(t, 0) <= POLICY_BASELINE_VERSION);
        scopedAfterBaseline.removeAll(declaredScoped.keySet());
        assertEquals(Set.of(), scopedAfterBaseline, "post-baseline COLUMN_SCOPED tables must be registered by a migration");
    }

    @Test
    void laterMigrationsNeverHandWriteAuditTriggersOrFullTableSweeps() throws Exception {
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            String sql = stripSqlComments(migration.sql()).replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
            String rowAuditSql = removeExactlyForwardRepairedAuditTrigger(migration, sql);
            if (migration.version() == 952) {
                String writer = "create trigger trg_audit_log_all_insert instead of insert on public.v_audit_log_all "
                        + "for each row execute function public.fn_audit_log_all_insert();";
                assertTrue(sql.contains(writer), "V952 must preserve only the exact audit-view INSERT forwarding trigger");
                rowAuditSql = sql.replace(writer, "");
            }
            assertFalse(rowAuditSql.contains("create trigger trg_audit_"),
                    migration.path().getFileName() + " must attach audit triggers through fn_audit_track_table");
            assertFalse(rowAuditSql.contains("execute function fn_audit()")
                            || rowAuditSql.contains("execute function public.fn_audit()"),
                    migration.path().getFileName() + " must not bind fn_audit without the three-list policy");
            assertFalse(migration.path().getFileName().toString().contains("refresh_audit_trigger_coverage"),
                    "Full-table audit sweeps are retired by ADR-105");
        }
    }

    private static String removeExactlyForwardRepairedAuditTrigger(MigrationSource migration, String sql) throws Exception {
        List<ForwardAuditRepair> repairs = FORWARD_AUDIT_REPAIRS.get(migration.version());
        for (ForwardAuditRepair repair : repairs == null ? List.<ForwardAuditRepair>of() : repairs) {
            assertEquals(repair.file(), migration.path().getFileName().toString());
            assertEquals(repair.sha256(), HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(Files.readAllBytes(migration.path()))), "Applied audit migration bytes must remain immutable");
            String forward = stripSqlComments(Files.readString(
                    MIGRATION_ROOT.resolve(repair.forwardFile()), StandardCharsets.UTF_8))
                    .replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
            assertTrue(forward.contains("select public.fn_audit_track_table('" + repair.table()
                    + "', 'full', 'data_change', false, null, true, null);"),
                    "The pinned historical mistake requires its exact public-policy forward registration");
            assertTrue(sql.contains(repair.legacyTrigger()),
                    "Only the known legacy trigger is covered by the forward correction");
            assertEquals(sql.indexOf(repair.legacyTrigger()), sql.lastIndexOf(repair.legacyTrigger()),
                    "The historical allowance covers one trigger only");
            sql = sql.replace(repair.legacyTrigger(), "");
        }
        if (DYNAMIC_LEGACY_AUDIT_FILE.getKey().equals(migration.path().getFileName().toString())) {
            assertEquals(DYNAMIC_LEGACY_AUDIT_FILE.getValue(), HexFormat.of().formatHex(
                            MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(migration.path()))),
                    "Applied audit migration bytes must remain immutable");
            int occurrences = 0;
            for (int at = sql.indexOf(DYNAMIC_LEGACY_AUDIT_TEMPLATE); at >= 0; at = sql.indexOf(
                    DYNAMIC_LEGACY_AUDIT_TEMPLATE, at + DYNAMIC_LEGACY_AUDIT_TEMPLATE.length())) {
                occurrences++;
            }
            assertEquals(DYNAMIC_LEGACY_AUDIT_TEMPLATE_OCCURRENCES, occurrences,
                    "the dynamic legacy audit template is pinned to its reviewed count");
            sql = sql.replace(DYNAMIC_LEGACY_AUDIT_TEMPLATE, "");
        }
        return removePinnedSubversionAuditTriggers(migration, sql);
    }

    private static String removePinnedSubversionAuditTriggers(MigrationSource migration, String sql)
            throws Exception {
        String filename = migration.path().getFileName().toString();
        PinnedSubversionAudit pinned = PINNED_SUBVERSION_AUDITS.stream()
                .filter(item -> item.file().equals(filename)).findFirst().orElse(null);
        if (pinned == null) return sql;
        assertEquals(pinned.sha256(), HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(Files.readAllBytes(migration.path()))),
                "Applied financial subversion bytes must remain immutable");
        String forward = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve(SUBVERSION_AUDIT_FORWARD), StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
        LegacyFinanceAudit exact=SEGMENTED_FINANCE_AUDIT_REPAIRS.get(filename);
        assertTrue(exact!=null,"Each Main SHA pin also requires its exact reviewed statement inventory");
        assertEquals(pinned.sha256(),exact.sha256(),"Main exact byte pin and statement inventory are one allowance");
        for(String trigger:exact.triggers()) {
            assertTrue(sql.contains(trigger),"Only the exact historical trigger statement is excused");
            assertEquals(sql.indexOf(trigger),sql.lastIndexOf(trigger),"Each pinned statement occurs once");
        }
        if(exact.dynamicTemplate()!=null) {
            assertTrue(sql.contains(exact.dynamicTemplate()));
            assertEquals(sql.indexOf(exact.dynamicTemplate()),sql.lastIndexOf(exact.dynamicTemplate()));
        }
        Matcher legacy = LEGACY_SUBVERSION_AUDIT.matcher(sql);
        int count = 0;
        while (legacy.find()) {
            count++;
            assertTrue(scopedTables().containsKey(legacy.group(2)),
                    "Every pinned private financial table needs a reviewed metadata-only policy");
            assertTrue(forward.contains("select public.fn_audit_track_table('" + legacy.group(2)
                            + "', 'column_scoped',"),
                    "The exact pinned historical trigger requires its V1059 forward registration");
        }
        assertEquals(pinned.staticTriggerCount(), count,
                "The allowance covers exactly the reviewed static audit triggers");
        sql = legacy.replaceAll("");
        if (filename.equals("V999_13__finance_open_item_classification_allocations.sql")) {
            String dynamic = "execute format('create trigger %i after insert on %i for each row execute function fn_audit()',table_name||'_audit',table_name);";
            assertEquals(sql.indexOf(dynamic), sql.lastIndexOf(dynamic));
            assertTrue(sql.contains(dynamic), "Only the pinned classification template is allowed");
            for (String table : List.of("finance_open_item_classification_batches", "finance_open_item_classification_parts",
                    "finance_payment_classification_batches", "finance_payment_classification_parts",
                    "finance_supplier_offset_classification_batches", "finance_supplier_offset_classification_parts")) {
                assertTrue(forward.contains("select public.fn_audit_track_table('" + table + "', 'column_scoped',"));
            }
            sql = sql.replace(dynamic, "");
        }
        return sql;
    }

    @Test
    void scopedRegistrationParserPreservesGenericAuditForExplicitNullUpdateFunction() {
        String registration = "fn_audit_track_table('scope_probe', 'COLUMN_SCOPED', 'system', false,"
                + " ARRAY['decision'], false";
        for (String optionalFunction : List.of("", ", NULL", ", NULL::text", ", null :: TEXT")) {
            Matcher scoped = SCOPED_CALL.matcher(registration + optionalFunction + ");");
            assertTrue(scoped.matches(), "generic audit registration must parse " + optionalFunction);
            assertEquals("scope_probe", scoped.group(1));
            assertEquals("system", scoped.group(2));
            assertEquals("'decision'", scoped.group(4));
            assertEquals("false", scoped.group(5));
            assertNull(scoped.group(6), "SQL NULL must retain the generic audit function and its column arguments");
        }
        Matcher narrow = SCOPED_CALL.matcher(registration + ", 'public.fn_audit_route_columns()');");
        assertTrue(narrow.matches());
        assertEquals("public.fn_audit_route_columns()", narrow.group(6));
        Matcher projectedRow = SCOPED_CALL.matcher(registration + ", NULL::text, 'public.fn_audit_stock_measurement_hold_columns()');");
        assertTrue(projectedRow.matches());
        assertNull(projectedRow.group(6));
        assertEquals("public.fn_audit_stock_measurement_hold_columns()", projectedRow.group(7));
        assertFalse(SCOPED_CALL.matcher(registration + ", NULL::integer);").matches(),
                "unsupported function argument types must not silently become generic audit");
    }

    @Test
    void createTableParserHandlesQuotedUnquotedAndDynamicIdentifiers() {
        Matcher plain = CREATE_TABLE.matcher("CREATE TABLE public.goods (id UUID)");
        assertTrue(plain.find());
        assertEquals("goods", plain.group(1));

        String quote = Character.toString(34);
        Matcher quoted = CREATE_TABLE.matcher("CREATE TABLE IF NOT EXISTS "
                + quote + "public" + quote + "." + quote + "Goods_Audit" + quote
                + " (id UUID)");
        assertTrue(quoted.find());
        assertEquals("Goods_Audit", quoted.group(1));

        Matcher partition = CREATE_TABLE.matcher("CREATE TABLE audit_log_p202609 PARTITION OF audit_log");
        assertTrue(partition.find());
        assertTrue(partition.group(2) != null, "partitions are not separate policy tables");

        assertFalse(CREATE_TABLE.matcher("EXECUTE format('CREATE TABLE IF NOT EXISTS %I', name)").find()
                        && "if".equalsIgnoreCase(firstCreated("EXECUTE format('CREATE TABLE IF NOT EXISTS %I', name)")),
                "dynamic names are not tables");
    }

    @Test
    void optionalIdentityMigrationsAreTablelessConstraintHardening()
            throws IOException {
        for (String filename : List.of(
                "V286__employee_sensitive_optional_primary_identity.sql",
                "V287__employee_sensitive_optional_identity_invariants.sql")) {
            String sql = stripSqlComments(Files.readString(
                    MIGRATION_ROOT.resolve(filename), StandardCharsets.UTF_8));
            assertFalse(CREATE_TABLE.matcher(sql).find(),
                    filename + " must stay tableless");
        }
    }

    @Test
    void v425BytesTouchOnlyAuditTablesAfterFreshChainGuardAllowsExecution()
            throws IOException {
        String sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V425__audit_log_fresh_start.sql"),
                        StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(sql.contains(
                "truncate table audit_log, audit_log_archive restart identity"),
                "Only after the fresh-chain guard allows V425, its frozen bytes must "
                        + "touch only the hot audit table and cold archive");
        assertFalse(sql.contains("delete from") || sql.contains("truncate table business"),
                "V425 must not touch business tables");
        String migrator = Files.readString(Path.of(
                "src/main/java/com/uten/imp/migration/UtenImpMigrator.java"),
                StandardCharsets.UTF_8);
        assertTrue(migrator.contains("new AuditFreshStartGuardCallback()"),
                "standalone migration must register the V425 fresh-chain guard");
    }

    @Test
    void v289BorrowGuardsStayAtTheDatabaseBoundary() throws IOException {
        String v288Sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V288__production_material_analysis_borrows.sql"),
                StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(v288Sql.contains(
                        "foreign key (analysis_id, from_material_id) references "
                                + "production_material_analysis_materials(analysis_id, id)")
                        && v288Sql.contains(
                        "foreign key (analysis_id, to_material_id) references "
                                + "production_material_analysis_materials(analysis_id, id)"),
                "V288 must bind both borrow endpoints to their declared analysis");
        String sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V289__refresh_audit_trigger_coverage.sql"),
                StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(sql.contains(
                        "create function fn_guard_production_material_analysis_borrow_mutation")
                        && sql.contains("new.status not in ('active', 'revoked')")
                        && sql.contains("deferrable initially deferred"),
                "V289 keeps the borrow lifecycle guards; its audit sweep is superseded by V670");
        assertTrue(fullTables().containsKey("production_material_analysis_borrows"),
                "A human borrow decision stays fully audited");
    }

    private static String firstCreated(String sql) {
        Matcher matcher = CREATE_TABLE.matcher(sql);
        return matcher.find() ? matcher.group(1) : "";
    }

    private static Map<String, String> literalFullAuditLoopRegistrations(String sql) {
        Pattern loopPattern = Pattern.compile("(?is)\\bFOREACH\\s+([a-z_][a-z0-9_]*)\\s+IN\\s+ARRAY\\s+ARRAY\\["
                + "((?:\\s*'[a-z_][a-z0-9_]*'\\s*,)*\\s*'[a-z_][a-z0-9_]*'\\s*)]\\s+LOOP\\b(.*?)\\bEND\\s+LOOP\\s*;");
        Map<String, String> registered = new LinkedHashMap<>();
        Matcher loop = loopPattern.matcher(sql);
        while (loop.find()) {
            String variable = Pattern.quote(loop.group(1));
            Pattern callPattern = Pattern.compile("(?i)\\bPERFORM\\s+(?:public\\.)?fn_audit_track_table\\(\\s*"
                    + variable + "\\s*,\\s*'FULL'\\s*,\\s*'(data_change|authorization|system)'\\s*,\\s*false"
                    + "\\s*,\\s*NULL\\s*,\\s*true\\s*,\\s*NULL\\s*\\)\\s*;");
            if (!callPattern.matcher(loop.group(3)).find()) continue;
            assertFalse(Pattern.compile("(?i)\\b" + variable + "\\s*:=").matcher(loop.group(3)).find(),
                    "A literal audit loop must not replace its table identity before registering it");
            Matcher table = QUOTED.matcher(loop.group(2));
            while (table.find()) registered.put(table.group(1), "FULL");
        }
        return registered;
    }

    @Test
    void literalFullAuditLoopsDoNotInferDynamicTableExpressions() {
        String body = " LOOP PERFORM fn_audit_track_table(t,'FULL','data_change',false,NULL,true,NULL); END LOOP;";
        assertEquals(Map.of("audit_probe_one", "FULL", "audit_probe_two", "FULL"),
                literalFullAuditLoopRegistrations("FOREACH t IN ARRAY ARRAY['audit_probe_one','audit_probe_two']" + body));
        assertEquals(Map.of(), literalFullAuditLoopRegistrations("FOREACH t IN ARRAY tables" + body));
        assertEquals(Map.of(), literalFullAuditLoopRegistrations("FOREACH t IN ARRAY ARRAY[table_name]" + body));
    }

    /** 迁移链结束时存在的表 -> 首次创建的版本(按建表/删表/改名依次回放)。 */
    static Map<String, Integer> liveTableVersions() throws IOException {
        Map<String, Integer> live = new LinkedHashMap<>();
        for (MigrationSource migration : migrations()) {
            String sql = stripSqlComments(migration.sql());
            List<Object[]> events = new ArrayList<>();
            Matcher create = CREATE_TABLE.matcher(sql);
            while (create.find()) {
                if (create.group(2) == null) {
                    events.add(new Object[]{create.start(), "create", create.group(1).toLowerCase(Locale.ROOT), null});
                }
            }
            Matcher drop = DROP_TABLE.matcher(sql);
            while (drop.find()) {
                for (String name : drop.group(1).split(",")) {
                    String[] parts = name.trim().split("\\.");
                    String table = parts[parts.length - 1].replace("\"", "").toLowerCase(Locale.ROOT);
                    events.add(new Object[]{drop.start(), "drop", table, null});
                }
            }
            Matcher rename = RENAME_TABLE.matcher(sql);
            while (rename.find()) {
                events.add(new Object[]{rename.start(), "rename",
                        rename.group(1).toLowerCase(Locale.ROOT), rename.group(2).toLowerCase(Locale.ROOT)});
            }
            events.sort(Comparator.comparingInt(event -> (Integer) event[0]));
            for (Object[] event : events) {
                String table = (String) event[2];
                switch ((String) event[1]) {
                    case "create" -> live.putIfAbsent(table, migration.version());
                    case "drop" -> live.remove(table);
                    default -> {
                        Integer version = live.remove(table);
                        if (version != null) {
                            live.put((String) event[3], version);
                        }
                    }
                }
            }
        }
        return live;
    }

    static List<MigrationSource> migrations() throws IOException {
        List<MigrationSource> result = new ArrayList<>();
        try (Stream<Path> files = Files.list(MIGRATION_ROOT)) {
            for (Path path : files.filter(Files::isRegularFile).toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(path.getFileName().toString());
                if (matcher.matches()) {
                    result.add(new MigrationSource(com.uten.imp.testsupport.FixtureNumbers.integer(matcher.group(1)), path,
                            Files.readString(path, StandardCharsets.UTF_8)));
                }
            }
        }
        result.sort(Comparator.comparing(migration -> MigrationVersion.fromVersion(
                migration.path().getFileName().toString().substring(1,
                        migration.path().getFileName().toString().indexOf("__")))));
        return result;
    }

    @Test
    void migrationScannerIncludesSubversionsInFlywayOrder() throws IOException {
        List<String> names = migrations().stream()
                .map(migration -> migration.path().getFileName().toString()).toList();
        int second = names.indexOf("V999_2__financial_voucher_evidence_and_auxiliary_allocations.sql");
        int tenth = names.indexOf("V999_10__procurement_reconciliation_first_payables.sql");
        int nextMajor = names.indexOf("V1001__business_application_workflows.sql");
        assertTrue(second >= 0 && second < tenth && tenth < nextMajor,
                "Subversions must participate in the policy replay in Flyway numeric order");
        assertEquals(999, liveTableVersions().get("finance_template_sources"));
    }

    @Test
    void financialSubversionCorrectionOnlyChangesSharedAuditPoliciesAndMinimization() throws IOException {
        String sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve(SUBVERSION_AUDIT_FORWARD), StandardCharsets.UTF_8));
        Matcher minimizer = Pattern.compile("(?s)DO \\$financial_subversion_private_changes\\$.*?"
                + "\\$financial_subversion_private_changes\\$;").matcher(sql);
        assertTrue(minimizer.find(), "The reviewed shared minimizer must retain redacted private-value changes");
        String body = minimizer.group();
        assertTrue(body.contains("pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)")
                        && body.contains("finance_source_payload_guard_v1")
                        && body.contains("EXECUTE replace(definition,anchor,projection);"));
        assertEquals(1, Pattern.compile("(?i)\\bEXECUTE\\b").matcher(body).results().count());
        assertFalse(Pattern.compile("(?i)\\b(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP)\\b").matcher(body).find(),
                "Only the canonical audit minimizer can be changed; business facts, guards and audit history stay intact");
        assertFalse(minimizer.find(), "The private-value minimizer has one reviewed writer");
        sql = Pattern.compile("(?s)DO \\$financial_subversion_private_changes\\$.*?"
                + "\\$financial_subversion_private_changes\\$;").matcher(sql).replaceAll("");
        for (String statement : sql.split(";")) {
            String normalized = statement.replaceAll("\\s+", " ").trim().toLowerCase(Locale.ROOT);
            if (normalized.isEmpty()) continue;
            assertTrue(normalized.startsWith("select public.fn_audit_track_table('")
                            || normalized.equals("select public.fn_refresh_finance_audit_metadata_projection()"),
                    "The forward correction must not alter business data, schema, guards or retained audit history");
        }
    }

    @Test
    void laterFinancialAuditDeltaPreservesMainPrivateScopesAndOnlyAddsReviewedMetadata() throws Exception {
        String main=Files.readString(MIGRATION_ROOT.resolve(SUBVERSION_AUDIT_FORWARD),StandardCharsets.UTF_8);
        assertEquals("f81b00750f54108c6af9f1ce51a8a78e3f558954c84afa345d31ffce3e8a6d92",HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(MIGRATION_ROOT.resolve(SUBVERSION_AUDIT_FORWARD)))),"Applied Main V1059 bytes remain immutable");
        assertTrue(main.contains("financial_subversion_private_changes_v1")&&main.contains("Private names, amounts"));
        String delta=stripSqlComments(Files.readString(MIGRATION_ROOT.resolve("V1078__financial_source_audit_policy_forward.sql"),StandardCharsets.UTF_8));
        Map<String,String> registrations=new HashMap<>();Matcher call=REGISTRATION.matcher(delta);
        while(call.find())assertNull(registrations.put(call.group(1),call.group(2)),"One additive registration per changed table");
        assertEquals(Set.of("finance_accounting_import_batches","finance_gl_entry_allocations","finance_gl_auxiliary_opening_evidence"),registrations.keySet());
        assertTrue(registrations.values().stream().allMatch("COLUMN_SCOPED"::equals));
        assertFalse(delta.contains("ARRAY['request_body'")||delta.contains("'result'")||delta.contains("'FULL'")||delta.contains("EXECUTE replace"));
        for(String table:List.of("finance_auxiliary_parties","finance_sales_cost_inputs","finance_procurement_ap_policy","finance_application_operations"))
            assertFalse(registrations.containsKey(table),"Main private changed-key/body exclusions are not overwritten");
    }
    /** Removes SQL comments so documentation examples cannot look like DDL. */
    static String stripSqlComments(String sql) {
        StringBuilder result = new StringBuilder(sql.length());
        boolean lineComment = false;
        boolean blockComment = false;
        boolean quoted = false;
        for (int index = 0; index < sql.length(); index++) {
            char current = sql.charAt(index);
            char next = index + 1 < sql.length() ? sql.charAt(index + 1) : '\0';
            if (lineComment) {
                if (current == '\n') {
                    lineComment = false;
                    result.append(current);
                }
                continue;
            }
            if (blockComment) {
                if (current == '*' && next == '/') {
                    blockComment = false;
                    index++;
                }
                continue;
            }
            if (!quoted && current == '-' && next == '-') {
                lineComment = true;
                index++;
                continue;
            }
            if (!quoted && current == '/' && next == '*') {
                blockComment = true;
                index++;
                continue;
            }
            if (current == '\'') {
                if (quoted && next == '\'') {
                    result.append(current).append(next);
                    index++;
                    continue;
                }
                quoted = !quoted;
            }
            result.append(current);
        }
        return result.toString();
    }

    record MigrationSource(int version, Path path, String sql) {
    }
}
