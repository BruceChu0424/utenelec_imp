package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.core.io.ClassPathResource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Pattern;
import java.util.UUID;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static com.uten.imp.support.LegacyFinanceImportFixture.*;

/** Real-schema smoke for the exact synthetic source used by the shell coordinator. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyFinanceImportSmokePostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;

    @BeforeAll static void start() {
        PG.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        seed(db);
    }
    @AfterAll static void stop() { PG.stop(); }

    @Test void originalReceiptKeepsItsFactsAndHasAnExactSourceProof() throws Exception {
        try(Connection connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
            connection.setAutoCommit(false);
            JdbcTemplate tx=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID run=context(tx);
            String loader=Files.readString(Path.of("legacy_migration/migrate_finance.sql"));
            var stage=Pattern.compile("CREATE TEMP TABLE m_get_stage \\(.*?;",Pattern.DOTALL).matcher(loader);
            assertThat(stage.find()).isTrue();
            tx.execute(stage.group());
            tx.update("INSERT INTO m_get_stage SELECT * FROM jsonb_populate_record(NULL::m_get_stage,?::jsonb)",source("m_get.csv"));
            // PostgreSQL resolves a bare same-named column before a whole-row alias.
            assertThat(tx.queryForObject("SELECT jsonb_typeof(to_jsonb(source)) FROM m_get_stage source",String.class))
                    .isEqualTo("string");
            assertThat(tx.queryForObject("SELECT jsonb_typeof(to_jsonb(legacy_row))||'|'||jsonb_typeof(to_jsonb(legacy_row.*)) "
                    +"FROM (SELECT 'synthetic'::text AS legacy_row,1 AS id) legacy_row",String.class))
                    .isEqualTo("string|object");
            var command=Pattern.compile("SELECT fn_import_legacy_finance_source\\(\\s*current_setting\\('uten.bootstrap_run_id'\\).*?'RECEIPT'.*?;",Pattern.DOTALL).matcher(loader);
            assertThat(command.find()).isTrue();
            UUID id=tx.queryForObject(command.group(),UUID.class);
            assertThat(tx.queryForObject("SELECT receipt_kind FROM finance_receipts WHERE id=?",String.class,id))
                    .isEqualTo("LEGACY_UNCLASSIFIED");
            assertThat(tx.queryForObject("SELECT amount_local FROM finance_receipts WHERE id=?",java.math.BigDecimal.class,id))
                    .isEqualByComparingTo("8");
            assertThat(tx.queryForObject("SELECT target_id FROM legacy_finance_import_sources WHERE run_id=?",UUID.class,run))
                    .isEqualTo(id);
            tx.update("UPDATE legacy_migration_runs SET status='SUCCESS' WHERE run_id=?",run);
            tx.execute("SET CONSTRAINTS ALL IMMEDIATE");
            connection.rollback();
        }
    }

    @Test void everyOriginalCashFamilyAndOpeningSurvivesDeferredFinalValidation() throws Exception {
        ObjectMapper mapper=new ObjectMapper();
        JsonNode base,variant;
        try(var input=new ClassPathResource("legacy-bootstrap-fixture/rows.json").getInputStream()){base=mapper.readTree(input);}
        try(var input=new ClassPathResource("legacy-bootstrap-fixture/variants/finance-facts.json").getInputStream()){variant=mapper.readTree(input);}
        try(Connection connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
            connection.setAutoCommit(false);
            JdbcTemplate tx=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID run=context(tx);
            tx.update("""
                    UPDATE legacy_migration_runs SET mapping_version='bootstrap-v19' WHERE run_id=?
                    """,run);
            tx.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v19'");
            tx.update("""
                    INSERT INTO payment_styles(legacy_id,code,name,category,status,is_receipt,is_payment)
                    VALUES(907010,'SYN-SECOND-ACCOUNT','Synthetic account leaf','ACCOUNT','使用',true,true),
                          (907011,'SYN-EXPENSE','Synthetic expense leaf','EXPENSE','使用',false,true),
                          (907012,'SYN-INCOME','Synthetic income leaf','INCOME','使用',true,false)
                    """);
            tx.update("""
                    INSERT INTO accounts(legacy_id,code,name,account_type,currency_id,style_id,
                        init_balance,receipts_total,payments_total,balance_current,status)
                    SELECT 907001,'SYN-SECOND','Synthetic second account','CASH',currency.id,style.id,0,20,5,15,'使用'
                    FROM currencies currency CROSS JOIN payment_styles style WHERE currency.legacy_id=1 AND style.legacy_id=907010
                    """);
            for(String[] kind:new String[][]{{"RECEIPT","m_get.csv"},{"PAYMENT","m_paid.csv"},{"EXPENSE","m_dpaid.csv"},
                    {"EXPENSE_ITEM","m_dpaid_item.csv"},{"INCOME","m_oget.csv"},{"INCOME_ITEM","m_oget_item.csv"},
                    {"ACCOUNT_FLOW","m_allcheck.csv"},{"AR_OPENING","m_in.csv"},{"AP_OPENING","m_out.csv"}}) {
                List<JsonNode> rows=new ArrayList<>();
                if(base.has(kind[1]))base.get(kind[1]).forEach(rows::add);
                if(variant.has(kind[1]))variant.get(kind[1]).forEach(rows::add);
                rows.sort(java.util.Comparator.comparingInt(row->row.get("legacy_id").asInt()));
                int line=0;
                for(JsonNode input:rows) {
                    ObjectNode complete=mapper.createObjectNode();
                    tx.queryForList("SELECT unnest(source_keys) FROM fn_legacy_finance_kind(?)",String.class,kind[0]).forEach(complete::putNull);
                    complete.setAll((ObjectNode)input);
                    tx.queryForObject("SELECT fn_import_legacy_finance_source(?,?,?::jsonb,?)",UUID.class,run,kind[0],complete.toString(),
                            kind[0].endsWith("_ITEM")?++line:null);
                }
            }
            assertThat(tx.queryForObject("SELECT count(DISTINCT source_kind) FROM legacy_finance_import_sources WHERE run_id=?",Integer.class,run)).isEqualTo(9);
            tx.execute("SELECT fn_rebuild_account_flow_monthly_summaries(NULL); SELECT fn_assert_account_flow_monthly_integrity(NULL)");
            tx.update("UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',finished_at=now(),exit_code=0 WHERE run_id=?",run);
            tx.execute("SET CONSTRAINTS ALL IMMEDIATE");
            assertThat(tx.queryForObject("SELECT amount_local FROM finance_expenses WHERE legacy_id=907003",java.math.BigDecimal.class)).isEqualByComparingTo("0");
            assertThat(tx.queryForObject("SELECT amount_original FROM finance_expenses WHERE legacy_id=907003",java.math.BigDecimal.class)).isEqualByComparingTo("2");
            connection.rollback();
        }
    }

    @Test void missingOriginalPaidDateNeedsTheExactTypedRowAndSameTransactionProof() throws Exception {
        try(Connection connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
            connection.setAutoCommit(false);
            JdbcTemplate tx=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID run=context(tx);
            tx.update("UPDATE legacy_migration_runs SET mapping_version='bootstrap-v19' WHERE run_id=?",run);
            tx.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v19'");
            String loader=Files.readString(Path.of("legacy_migration/migrate_finance.sql"));
            for(String table:new String[]{"m_in_stage","m_out_stage"}) {
                var matcher=Pattern.compile("CREATE TEMP TABLE "+table+" \\(.*?;",Pattern.DOTALL).matcher(loader);
                assertThat(matcher.find()).isTrue();tx.execute(matcher.group());
            }
            ObjectNode original=(ObjectNode)new ObjectMapper().readTree(source("m_in.csv"));
            original.put("total",5);original.put("settled",5);original.put("balance",0);original.putNull("paid_date");
            tx.update("INSERT INTO m_in_stage SELECT * FROM jsonb_populate_record(NULL::m_in_stage,?::jsonb)",original.toString());
            // Use the actual typed stage tuple, just as the reviewed loader does.
            tx.queryForObject("SELECT fn_import_legacy_finance_source(?,'AR_OPENING',to_jsonb(s.*)) FROM m_in_stage s",UUID.class,run);
            int start=loader.indexOf("ANALYZE public.legacy_finance_import_sources;");
            assertThat(start).isGreaterThan(0);
            String verifier=loader.substring(start,loader.indexOf("DO $$",start));
            var matcher=Pattern.compile("SELECT COUNT\\(\\*\\) INTO broken_count\\s+FROM public.ar_ap_ledger ledger.*?;",Pattern.DOTALL).matcher(loader);
            assertThat(matcher.find()).isTrue();String violations=matcher.group().replace(" INTO broken_count","");
            tx.execute(verifier);
            assertThat(tx.queryForObject("SELECT count(*) FROM finance_verified_missing_settlement_date_stage",Integer.class)).isEqualTo(1);
            assertThat(tx.queryForObject(violations,Integer.class)).isZero();
            for(String mutation:new String[]{
                    "UPDATE m_in_stage SET note='Synthetic changed source payload'",
                    "UPDATE m_in_stage SET paid_date='2025-01-03T00:00:00Z'",
                    "UPDATE legacy_migration_run_files SET sha256=repeat('0',64) WHERE file_name='m_in.csv' AND run_id='"+run+"'"}) {
                var save=connection.setSavepoint();tx.execute(mutation);
                tx.execute("DROP TABLE finance_verified_missing_settlement_date_stage");tx.execute(verifier);
                assertThat(tx.queryForObject(violations,Integer.class)).isEqualTo(1);
                connection.rollback(save);
            }
            tx.update("UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',exit_code=0,finished_at=now() WHERE run_id=?",run);
            tx.execute("SET CONSTRAINTS ALL IMMEDIATE");connection.rollback();
        }
    }

}
