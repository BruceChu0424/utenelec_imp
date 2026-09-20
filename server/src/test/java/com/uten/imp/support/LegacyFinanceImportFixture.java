package com.uten.imp.support;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.UUID;

/** Exact synthetic source rows and the real database import capability for integration fixtures. */
public final class LegacyFinanceImportFixture {
    private LegacyFinanceImportFixture() { }

    public static String source(String file) throws Exception {
        try (var input = new org.springframework.core.io.ClassPathResource(
                "legacy-bootstrap-fixture/rows.json").getInputStream()) {
            return new ObjectMapper().readTree(input).get(file).get(0).toString();
        }
    }

    public static UUID context(JdbcTemplate jdbc) {
        jdbc.execute("SET LOCAL uten.legacy_reference_import='legacy-finance-v273'");
        UUID run=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO legacy_migration_runs(run_id,target,status,migration_mode,mapping_version,
                  migration_repository_commit,export_manifest_sha256,checksum_manifest_sha256,migration_script_sha256,
                  source_backup_sha256,export_approval_reference,reconciliation_summary)
                VALUES(?,'--bootstrap-all','RUNNING','BOOTSTRAP','bootstrap-v11',repeat('a',40),repeat('b',64),
                  repeat('c',64),repeat('d',64),repeat('e',64),'synthetic-reviewed-source',
                  jsonb_build_object('importAtomicity','single-transaction-v1','targetDatabase',current_database(),
                    'targetApprovalReference','synthetic-reviewed-target','sourceSnapshotAsOfUtc','2025-01-31T15:59:59Z',
                    'targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())))
                """,run);
        for(String file:new String[]{"m_get.csv","m_paid.csv","m_dpaid.csv","m_oget.csv","m_dpaid_item.csv",
                "m_oget_item.csv","m_allcheck.csv","m_in.csv","m_out.csv"}) {
            jdbc.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500)",run,file);
        }
        jdbc.queryForObject("SELECT set_config('uten.bootstrap_run_id',?,true)",String.class,run.toString());
        jdbc.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v11'; SET LOCAL uten.bootstrap_repository_commit='"
                +"a".repeat(40)+"'; SET LOCAL uten.bootstrap_manifest_sha='"+"b".repeat(64)+"'");
        jdbc.execute("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");
        return run;
    }

    public static void seed(JdbcTemplate jdbc) {
        jdbc.update("INSERT INTO clients(legacy_id,code,name,status,code_sequence) VALUES(900501,'SYN-FIN-CLIENT','Synthetic client','禁用',1)");
        jdbc.update("INSERT INTO suppliers(legacy_id,code,name,status,code_sequence) VALUES(900601,'SYN-FIN-SUPPLIER','Synthetic supplier','禁用',1)");
        jdbc.update("""
                INSERT INTO employees(legacy_id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(900701,'LEGACY-W-900701','Synthetic worker','其他',
                  (SELECT id FROM departments WHERE code='DEPT_HR'),'2000-01-01','resigned','regular')
                """);
        jdbc.update("""
                INSERT INTO payment_styles(legacy_id,code,name,category,status,is_receipt,is_payment)
                VALUES(906010,'SYN-FIN-STYLE','Synthetic cash leaf','ACCOUNT','使用',true,true)
                """);
        jdbc.update("""
                INSERT INTO accounts(legacy_id,code,name,account_type,currency_id,style_id,
                  init_balance,receipts_total,payments_total,balance_current,status)
                SELECT 906001,'SYN-FIN-ACCOUNT','Synthetic cash account','CASH',currency.id,style.id,0,8,0,8,'使用'
                FROM currencies currency CROSS JOIN payment_styles style
                WHERE currency.legacy_id=1 AND style.legacy_id=906010
                """);
        jdbc.update("""
                INSERT INTO finance_payment_methods(legacy_id,code,name,is_receipt,is_payment,status,legacy_name_confirmed)
                VALUES(1,'SYN-FIN-METHOD','Synthetic method',true,true,'使用',true)
                ON CONFLICT(legacy_id) DO NOTHING
                """);
    }
}
