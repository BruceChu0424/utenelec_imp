package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

/** Actual migrated transactions prove import replay, native account creation and allocation rollback. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceChartImportPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceChartImportPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired JdbcTemplate db;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void forwardFinancialAuditUsesRealHelpersAndNeverCopiesPrivateSourceBodies()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-audit-forward");fixture.loginAs(world.superAdminUserId());
        String forward;
        try(var input=getClass().getResourceAsStream("/db/migration/V1050__financial_source_audit_policy_forward.sql")) {
            forward=new String(java.util.Objects.requireNonNull(input).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
        var names=new java.util.ArrayList<String>();
        var matcher=java.util.regex.Pattern.compile("fn_audit_track_table\\('([a-z_]+)'").matcher(forward);
        while(matcher.find())names.add(matcher.group(1));
        assertThat(names).hasSize(57).doesNotHaveDuplicates();
        String tables=names.stream().map(name->"'"+name+"'").collect(java.util.stream.Collectors.joining(","));
        var guardsBefore=financialGuardDefinitions(tables);
        java.util.UUID source=java.util.UUID.randomUUID();String marker="PRIVATE-SOURCE-"+source;
        db.update("""
                INSERT INTO finance_statement_source_reviews(id,actor_id,kind,source_system,currency_id,date_from,date_to,
                    source_name,sha256,storage_provider,storage_key,storage_size,preview)
                VALUES(?,?,'AUXILIARY_RECEIVABLE',?,?,DATE '2026-01-01',DATE '2026-01-31',
                    'anonymous-private-source.xls',repeat('a',64),'local',?,1,jsonb_build_object('privateProbe',?::text))
                """,source,world.superAdminUserId(),"ANON-AUDIT-"+source,world.currencyId(),"anonymous-"+source,marker);
        String factsBefore=db.queryForObject("SELECT to_jsonb(s)::text FROM finance_statement_source_reviews s WHERE id=?",String.class,source);
        String auditBefore=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString());
        assertThat(auditBefore).isNotNull().doesNotContain(marker,"preview","directory_result","storage_key");

        // Reapply the actual forward registrar inside one transaction. No fixture helper,
        // trigger suppression, old migration rewrite or historical-row cleanup is used.
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->db.execute(forward));
        assertThat(financialGuardDefinitions(tables)).isEqualTo(guardsBefore);
        assertThat(db.queryForObject("SELECT to_jsonb(s)::text FROM finance_statement_source_reviews s WHERE id=?",String.class,source)).isEqualTo(factsBefore);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString())).isEqualTo(auditBefore);

        for(String table:names) {
            var auditTriggers=db.queryForList("SELECT tgname,tgenabled::text FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND NOT tgisinternal AND tgfoid='public.fn_audit()'::regprocedure",table);
            if(java.util.Set.of("finance_gl_period_versions","finance_cost_input_operations","finance_asset_template_operations").contains(table)) {
                assertThat(auditTriggers).isEmpty();continue;
            }
            assertThat(auditTriggers).hasSize(2);
            assertThat(auditTriggers).extracting(row->row.get("tgname")).containsExactlyInAnyOrder(
                    ("trg_audit_"+table).substring(0,Math.min(63,10+table.length())),
                    ("trg_audit_upd_"+table).substring(0,Math.min(63,14+table.length())));
            assertThat(auditTriggers).allSatisfy(row->assertThat(row.get("tgenabled")).isEqualTo("A"));
            var columns=db.queryForList("SELECT unnest(fn_finance_audit_metadata_columns(?))",String.class,table);
            if(!columns.isEmpty())assertThat(columns).doesNotContain("preview","directory_result","result","reviewed_input",
                    "source_snapshot","auxiliary_snapshot","source_entry_snapshot","member_snapshot","zero_balance_evidence",
                    "reported_value","amount_original","amount_local","opening_debit","opening_credit","exchange_rate");
        }
        assertThat(db.queryForList("SELECT unnest(fn_finance_audit_metadata_columns('finance_statement_source_reviews'))",String.class))
                .containsExactly("id","actor_id","kind","currency_id","date_from","date_to","sha256","currency_mapping_fingerprint","created_at","directory_applied_at");
        db.update("UPDATE finance_statement_source_reviews SET directory_result=jsonb_build_object('privateResult',?::text),directory_applied_at=now() WHERE id=?",marker,source);
        String later=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString());
        assertThat(later).contains("directory_applied_at").doesNotContain(marker,"preview","directory_result");
        assertThatThrownBy(()->db.update("UPDATE finance_statement_source_reviews SET preview='{}'::jsonb WHERE id=?",source))
                .hasMessageContaining("不可覆盖");
    }

    private java.util.Map<String,String> financialGuardDefinitions(String tables) {
        var result=new java.util.TreeMap<String,String>();
        db.queryForList("""
                SELECT c.relname||':trigger:'||t.tgname AS name,
                    t.tgenabled::text||':'||pg_get_triggerdef(t.oid)||':'||pg_get_functiondef(t.tgfoid) AS definition
                FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                WHERE c.relnamespace='public'::regnamespace AND c.relname IN (%s) AND NOT t.tgisinternal
                  AND t.tgfoid NOT IN('public.fn_audit()'::regprocedure,'public.fn_audit_route_columns()'::regprocedure)
                UNION ALL SELECT conrelid::regclass::text||':constraint:'||conname,pg_get_constraintdef(oid)
                FROM pg_constraint WHERE conrelid IN(SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname IN(%s))
                """.formatted(tables,tables)).forEach(row->result.put(row.get("name").toString(),row.get("definition").toString()));
        return result;
    }
    @Test void directoryReadKeepsOneSnapshotWhenAnotherTransactionAddsACodeBetweenItsQueries()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-chart-read-snapshot");fixture.loginAs(world.superAdminUserId());
        chart.apply(new FinanceChartContracts.Apply(chart.preview("chart.xls",getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes()).importId()));
        var target=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(chart);
        var original=(com.uten.imp.application.port.FinancialChartCurrencyReadPort)org.springframework.test.util.ReflectionTestUtils.getField(target,"chartCurrencies");
        var inserted=new java.util.concurrent.atomic.AtomicBoolean();
        var independent=new org.springframework.transaction.support.TransactionTemplate(transactions);
        independent.setPropagationBehavior(org.springframework.transaction.TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        var currencyRead=new com.uten.imp.application.port.FinancialChartCurrencyReadPort() {
            @Override public java.util.List<Choice> choices(){return original.choices();}
            @Override public java.util.Map<String,Reference> read(java.util.Set<String> codes) {
                if(inserted.compareAndSet(false,true)) {
                    independent.executeWithoutResult(status->chart.createAccount(new FinanceChartContracts.CreateAccount(
                            java.util.UUID.randomUUID(),"990001","并发新增科目","",null,"匿名并发目录证据","ASSET",null)));
                }
                return original.read(codes);
            }
        };
        org.springframework.test.util.ReflectionTestUtils.setField(target,"chartCurrencies",currencyRead);
        try {
            try {
                assertThat(chart.list()).hasSize(177).noneMatch(account->account.code().equals("990001"));
            } finally {
                org.springframework.test.util.ReflectionTestUtils.setField(target,"chartCurrencies",original);
            }
            assertThat(inserted).isTrue();
            assertThat(chart.list()).hasSize(178).anyMatch(account->account.code().equals("990001"));
        } finally {
            // Only the unbound anonymous fixture code is removed; its operation
            // receipt and audit facts remain, as do all original imported codes.
            db.update("DELETE FROM finance_chart_codes WHERE code='990001'");
        }
    }
    @Test void metadataRenameKeepsTheOriginalImportAndMappingsWhileReplayingTheOriginalReceipt()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-chart-metadata");fixture.loginAs(world.superAdminUserId());
        var imported=chart.preview("chart.xls",getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes());
        chart.apply(new FinanceChartContracts.Apply(imported.importId()));
        var original=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        chart.createTarget("1001",new FinanceChartContracts.CreateTarget(original.version(),"ACCOUNT",null,null,"BS_1",null));
        var mapped=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        String evidenceBefore=db.queryForObject("SELECT (to_jsonb(c)-ARRAY['name','row_version','updated_at','updated_by'])::text FROM finance_chart_codes c WHERE code='1001'",String.class);
        var mappingsBefore=db.queryForList("SELECT * FROM finance_chart_code_styles WHERE code='1001'");
        var bindingsBefore=db.queryForList("SELECT * FROM finance_chart_owned_bindings WHERE code='1001'");
        int entriesBefore=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
        var command=new FinanceChartContracts.UpdateAccount(java.util.UUID.randomUUID(),mapped.version(),"库存现金（本币）","核对原目录名称");
        var receipt=chart.updateAccount("1001",command);
        assertThat(receipt).isEqualTo(new FinanceChartContracts.UpdateAccountResult(command.requestId(),"1001","UPDATED",mapped.name(),command.name(),command.sourceReference()));
        var renamed=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThat(renamed.version()).isEqualTo(mapped.version()+1);
        assertThat(renamed.targets()).isEqualTo(mapped.targets());
        assertThat(renamed.lineKeys()).isEqualTo(mapped.lineKeys());
        assertThat(renamed.currencyId()).isEqualTo(mapped.currencyId());
        assertThat(db.queryForObject("SELECT (to_jsonb(c)-ARRAY['name','row_version','updated_at','updated_by'])::text FROM finance_chart_codes c WHERE code='1001'",String.class)).isEqualTo(evidenceBefore);
        assertThat(db.queryForList("SELECT * FROM finance_chart_code_styles WHERE code='1001'")).isEqualTo(mappingsBefore);
        assertThat(db.queryForList("SELECT * FROM finance_chart_owned_bindings WHERE code='1001'")).isEqualTo(bindingsBefore);

        chart.updateAccount("1001",new FinanceChartContracts.UpdateAccount(java.util.UUID.randomUUID(),renamed.version(),"库存现金（已复核）","后续独立修改"));
        long latestVersion=db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code='1001'",Long.class);
        assertThat(chart.updateAccount("1001",command)).isEqualTo(receipt);
        assertThat(chart.metadataReceipt("1001",command.requestId())).containsEntry("found",true).containsEntry("result",receipt);
        assertThat(db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code='1001'",Long.class)).isEqualTo(latestVersion);
        assertThat(db.queryForObject("SELECT name FROM finance_chart_codes WHERE code='1001'",String.class)).isEqualTo("库存现金（已复核）");
        assertThatThrownBy(()->chart.updateAccount("1001",new FinanceChartContracts.UpdateAccount(command.requestId(),command.expectedVersion(),"换正文",command.sourceReference())))
                .isInstanceOf(ApiException.class).hasMessageContaining("同一修改请求");
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(entriesBefore);

        var other=fixture.seedWorld("finance-chart-metadata-other");fixture.loginAs(other.superAdminUserId());
        assertThat(chart.metadataReceipt("1001",command.requestId())).containsEntry("found",false);
        assertThatThrownBy(()->chart.updateAccount("1001",command)).isInstanceOf(ApiException.class).hasMessageContaining("同一修改请求");
    }
    @Test void nativeAccountAndBothSelectedReportBindingsAreAtomicAndReplayable()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-chart-create-lines");fixture.loginAs(world.superAdminUserId());
        chart.apply(new FinanceChartContracts.Apply(chart.preview("chart.xls",getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes()).importId()));
        var equity=chart.list().stream().filter(a->a.code().equals("310410")).findFirst().orElseThrow();
        var command=new FinanceChartContracts.CreateTarget(equity.version(),"EQUITY","EQUITY",null,"BS_51","PL_PRIOR_ADJUSTMENT");
        chart.createTarget(equity.code(),command);chart.createTarget(equity.code(),command);
        var saved=chart.list().stream().filter(a->a.code().equals(equity.code())).findFirst().orElseThrow();
        assertThat(saved.targets()).hasSize(1);
        assertThat(saved.lineKeys()).containsExactlyInAnyOrder("BS_51","PL_PRIOR_ADJUSTMENT");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_owned_bindings WHERE code=?",Integer.class,equity.code())).isEqualTo(2);
        // An old four-argument create command is not an instruction to remove
        // later explicit BS/PL mappings, even with the latest expected version.
        chart.createTarget(equity.code(),new FinanceChartContracts.CreateTarget(saved.version(),"EQUITY","EQUITY",null));
        var afterLegacyCreate=chart.list().stream().filter(a->a.code().equals(equity.code())).findFirst().orElseThrow();
        assertThat(afterLegacyCreate).isEqualTo(saved);
        assertThat(db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code=?",Long.class,equity.code())).isEqualTo(saved.version());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_owned_bindings WHERE code=?",Integer.class,equity.code())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT currency_id FROM finance_chart_codes WHERE code=?",java.util.UUID.class,equity.code())).isEqualTo(saved.currencyId());
        chart.createTarget(equity.code(),new FinanceChartContracts.CreateTarget(saved.version(),"EQUITY","EQUITY",null," ",""));
        assertThat(chart.list().stream().filter(a->a.code().equals(equity.code())).findFirst().orElseThrow()).isEqualTo(saved);
        assertThat(db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code=?",Long.class,equity.code())).isEqualTo(saved.version());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_owned_bindings WHERE code=?",Integer.class,equity.code())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT currency_id FROM finance_chart_codes WHERE code=?",java.util.UUID.class,equity.code())).isEqualTo(saved.currencyId());
        chart.createTarget(equity.code(),command);
        assertThat(chart.list().stream().filter(a->a.code().equals(equity.code())).findFirst().orElseThrow()).isEqualTo(saved);
        var before=chart.list().stream().filter(a->a.code().equals("100201")).findFirst().orElseThrow();
        int styles=db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class);
        assertThatThrownBy(()->chart.createTarget("100201",new FinanceChartContracts.CreateTarget(before.version(),"ACCOUNT","ASSET",null,"BS_1","PL_1")))
                .isInstanceOf(ApiException.class);
        var after=chart.list().stream().filter(a->a.code().equals("100201")).findFirst().orElseThrow();
        assertThat(after).isEqualTo(before);
        assertThat(db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class)).isEqualTo(styles);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_owned_bindings WHERE code='100201'",Integer.class)).isZero();
    }
    @Test void all177OriginalCodesImportWithoutMoneyAndNativeMappingIsAtomicAndReplayable()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-chart");fixture.loginAs(world.superAdminUserId());
        int journalBefore=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
        byte[] source=getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes();
        var preview=chart.preview("2026年9月份科目余额表代码.xls",source);
        assertThat(preview.rows()).hasSize(177);assertThat(preview.issues()).isEmpty();
        var applied=chart.apply(new FinanceChartContracts.Apply(preview.importId()));
        assertThat(applied.imported()).isEqualTo(177);
        assertThat(chart.apply(new FinanceChartContracts.Apply(preview.importId()))).isEqualTo(applied);
        assertThat(chart.preview("同一文件.xls",source).importId()).isEqualTo(preview.importId());
        assertThat(chart.list()).hasSize(177);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journalBefore);
        var account=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        var create=new FinanceChartContracts.CreateTarget(account.version(),"ACCOUNT",null,null,"BS_1",null);
        chart.createTarget("1001",create);chart.createTarget("1001",create);
        account=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThat(account.targets()).hasSize(1);var nativeId=account.targets().getFirst().id();
        assertThat(account.lineKeys()).containsExactly("BS_1");
        var mapping=new FinanceChartContracts.Mapping(account.version(),List.of(nativeId),"BS_1",null);
        chart.map("1001",mapping);chart.map("1001",mapping);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='BS_1' AND style_id=?",Integer.class,nativeId)).isEqualTo(1);
        var bank=chart.list().stream().filter(a->a.code().equals("100201")).findFirst().orElseThrow();
        assertThatThrownBy(()->chart.map("100201",new FinanceChartContracts.Mapping(bank.version(),List.of(nativeId),"BS_1",null)))
                .isInstanceOf(ApiException.class).hasMessageContaining("重复归集");
        var current=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThatThrownBy(()->chart.map("1001",new FinanceChartContracts.Mapping(current.version(),List.of(nativeId),null,"PL_1")))
                .isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='BS_1' AND style_id=?",Integer.class,nativeId)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journalBefore);
        var other=fixture.seedWorld("finance-chart-other");fixture.loginAs(other.superAdminUserId());
        assertThatThrownBy(()->chart.imported(preview.importId())).isInstanceOf(ApiException.class).hasMessageContaining("不属于当前账号");
    }
}
