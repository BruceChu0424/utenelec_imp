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
    @Autowired com.fasterxml.jackson.databind.ObjectMapper json;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @Autowired com.uten.imp.common.storage.ImmutableDocumentStore documents;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void historicalChartPreviewCannotWriteOrRewriteItsSourceAndAnotherOwnerCannotUseIt() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("legacy-chart-column-safety");fixture.loginAs(world.superAdminUserId());
        byte[] bytes=getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes();
        java.util.UUID id=java.util.UUID.randomUUID();String hash=com.uten.imp.common.storage.ImmutableDocumentStore.digest(bytes);
        var parser=Class.forName("com.uten.imp.features.finance.gl.FinanceChartWorkbookParser").getDeclaredMethod("parse",java.util.UUID.class,String.class,String.class,byte[].class);parser.setAccessible(true);
        var parsed=(FinanceChartContracts.Preview)parser.invoke(null,id,"legacy.xls",hash,bytes);
        var raw=(com.fasterxml.jackson.databind.node.ObjectNode)json.valueToTree(parsed);raw.remove("columnContractVersion");
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            var stored=documents.save("FINANCE_CHART_IMPORT","legacy.xls","application/vnd.ms-excel",bytes);
            db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview) VALUES(?,?,'legacy.xls',?,?,?,?,?,?::jsonb)",
                    id,world.superAdminUserId(),hash,stored.provider(),stored.key(),stored.version(),stored.size(),raw.toString());
        });
        String original=db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,id);
        int codes=db.queryForObject("SELECT count(*) FROM finance_chart_codes",Integer.class),entries=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
        assertThatThrownBy(()->chart.apply(new FinanceChartContracts.Apply(id))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        assertThatThrownBy(()->chart.repreview(id,json.valueToTree(new FinanceChartContracts.Repreview(java.util.UUID.randomUUID()))))
                .isInstanceOf(ApiException.class).hasMessageContaining("仅改文件名");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes",Integer.class)).isEqualTo(codes);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(entries);
        assertThat(db.queryForObject("SELECT applied_result::text FROM finance_chart_imports WHERE id=?",String.class,id)).isNull();
        assertThat(db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,id)).isEqualTo(original);
        var other=fixture.seedWorld("legacy-chart-other-owner");fixture.loginAs(other.superAdminUserId());
        assertThatThrownBy(()->chart.imported(id)).isInstanceOf(ApiException.class);
    }

    @Test void forwardFinancialAuditUsesRealHelpersAndNeverCopiesPrivateSourceBodies()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-audit-forward");fixture.loginAs(world.superAdminUserId());
        String main,delta,importDelta;
        try(var input=getClass().getResourceAsStream("/db/migration/V1059__financial_subversion_audit_policy_registration.sql")) {
            main=new String(java.util.Objects.requireNonNull(input).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
        try(var input=getClass().getResourceAsStream("/db/migration/V1078__financial_source_audit_policy_forward.sql")) {
            delta=new String(java.util.Objects.requireNonNull(input).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
        try(var input=getClass().getResourceAsStream("/db/migration/V1090__finance_chart_import_original_intents.sql")) {
            importDelta=new String(java.util.Objects.requireNonNull(input).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
        var calls=java.util.regex.Pattern.compile("(?s)SELECT\\s+public\\.fn_audit_track_table\\('([a-z_]+)'\\s*,\\s*'([A-Z_]+)'\\s*,\\s*'[^']+'\\s*,\\s*(?:true|false)\\s*,\\s*(ARRAY\\[(.*?)\\]|NULL)\\s*,\\s*true\\s*,\\s*NULL\\s*\\);");
        var names=new java.util.ArrayList<String>();var policies=new java.util.LinkedHashMap<String,String>();
        var expectedColumns=new java.util.LinkedHashMap<String,java.util.List<String>>();var registration=new StringBuilder();
        for(String sql:java.util.List.of(main,delta,importDelta)) {
            var matcher=calls.matcher(sql);int count=0;
            while(matcher.find()) {
                count++;String table=matcher.group(1);if(sql.equals(main)){
                    names.add(table);
                }

                policies.put(table,matcher.group(2));registration.append(matcher.group()).append('\n');
                var columns=new java.util.ArrayList<String>();var column=java.util.regex.Pattern.compile("'([^']+)'").matcher(matcher.group(4)==null?"":matcher.group(4));
                while(column.find()){
                    columns.add(column.group(1));
                }
                expectedColumns.put(table,columns);
            }
            assertThat(count).isEqualTo(sql.equals(main)?57:sql.equals(delta)?3:1);
        }
        assertThat(names).doesNotHaveDuplicates();
        assertThat(policies.get("finance_application_operations")).isEqualTo("COLUMN_SCOPED");
        String tables=names.stream().map(name->"'"+name+"'").collect(java.util.stream.Collectors.joining(","));
        var guardsBefore=financialGuardDefinitions(tables);
        String minimizerBefore=db.queryForObject("SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)",String.class);
        assertThat(minimizerBefore).contains("financial_subversion_private_changes_v1");
        java.util.UUID source=java.util.UUID.randomUUID();String marker="PRIVATE-SOURCE-"+source;
        db.update("""
                INSERT INTO finance_statement_source_reviews(id,actor_id,kind,source_system,currency_id,date_from,date_to,
                    source_name,sha256,storage_provider,storage_key,storage_size,preview)
                VALUES(?,?,'AUXILIARY_RECEIVABLE',?,?,DATE '2026-01-01',DATE '2026-01-31',
                    'anonymous-private-source.xls',repeat('a',64),'local',?,1,jsonb_build_object('privateProbe',?::text))
                """,source,world.superAdminUserId(),"ANON-AUDIT-"+source,world.currencyId(),"anonymous-"+source,marker);
        String factsBefore=db.queryForObject("SELECT to_jsonb(s)::text FROM finance_statement_source_reviews s WHERE id=?",String.class,source);
        String auditBefore=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString());
        assertThat(auditBefore).isNotNull().doesNotContain(marker,"anonymous-private-source.xls","anonymous-"+source);
        // Replay Main57 plus the3 original and1 import-safe additive registrars. The
        // already-applied minimizer DO is deliberately not re-executed or replaced.
        String publicRegistrations=registration+"SELECT public.fn_refresh_finance_audit_metadata_projection();";
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{db.execute(publicRegistrations);db.execute(publicRegistrations);});
        assertThat(financialGuardDefinitions(tables)).isEqualTo(guardsBefore);
        assertThat(db.queryForObject("SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)",String.class)).isEqualTo(minimizerBefore);
        assertThat(db.queryForObject("SELECT to_jsonb(s)::text FROM finance_statement_source_reviews s WHERE id=?",String.class,source)).isEqualTo(factsBefore);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString())).isEqualTo(auditBefore);
        for(String table:names) {
            var auditTriggers=db.queryForList("SELECT tgname,tgenabled::text FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND NOT tgisinternal AND tgfoid='public.fn_audit()'::regprocedure",table);
            if("NONE".equals(policies.get(table))){assertThat(auditTriggers).isEmpty();continue;}
            assertThat(auditTriggers).hasSize(2);
            assertThat(auditTriggers).extracting(row->row.get("tgname")).containsExactlyInAnyOrder(
                    ("trg_audit_"+table).substring(0,Math.min(63,10+table.length())),("trg_audit_upd_"+table).substring(0,Math.min(63,14+table.length())));
            assertThat(auditTriggers).allSatisfy(row->assertThat(row.get("tgenabled")).isEqualTo("A"));
            assertThat(db.queryForList("SELECT unnest(fn_finance_audit_metadata_columns(?))",String.class,table)).containsExactlyElementsOf(expectedColumns.get(table));
        }
        assertThat(expectedColumns.get("finance_application_operations")).doesNotContain("result","request_body","amount_original","amount_local");
        db.update("UPDATE finance_statement_source_reviews SET directory_result=jsonb_build_object('privateResult',?::text),directory_applied_at=now() WHERE id=?",marker,source);
        String later=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_statement_source_reviews' AND target_id=?",String.class,source.toString());
        assertThat(later).contains("directory_applied_at").doesNotContain(marker);
        assertThatThrownBy(()->db.update("UPDATE finance_statement_source_reviews SET preview='{}'::jsonb WHERE id=?",source)).hasMessageContaining("不可覆盖");
        String period=com.uten.imp.common.time.BusinessTime.today().toString().substring(0,7);
        String number="987.123456789012345678901234",privateUpdate=marker+"-CHANGED";
        java.util.UUID otherClient=java.util.UUID.randomUUID();
        db.update("INSERT INTO clients(id,code,name,status,code_sequence)VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))",otherClient,"AUDIT-"+otherClient,"匿名同月第二财务客户");
        for(var client:java.util.List.of(world.clientId(),otherClient)){
            db.update("INSERT INTO finance_sales_cost_inputs(period,client_id,source_reference,freight_local,updated_by)VALUES(?,?,?,1,?)",period,client,marker,world.superAdminUserId());
        }

        long updateAnchor=db.queryForObject("SELECT coalesce(max(id),0) FROM audit_log",Long.class);
        for(var client:java.util.List.of(world.clientId(),otherClient)){
            assertThat(db.update("UPDATE finance_sales_cost_inputs SET source_reference=?,freight_local=?::numeric,row_version=row_version+1 WHERE period=? AND client_id=?",privateUpdate,number,period,client)).isEqualTo(1);
        }

        var updates=db.queryForList("SELECT to_jsonb(a)::text FROM audit_log a WHERE target_type='finance_sales_cost_inputs' AND action='update' AND id>? ORDER BY id",String.class,updateAnchor);
        assertThat(updates).hasSize(2);var actualClients=new java.util.HashSet<String>();
        for(String value:updates){
            var event=com.uten.imp.common.finance.FinancialJsonResults.tree(json,value);
            assertThat(event.path("target_id").asText()).isEqualTo(period);
            assertThat(event.path("before").path("period").asText()).isEqualTo(period);
            assertThat(event.path("after").path("period").asText()).isEqualTo(period);
            String client=event.path("before").path("client_id").asText();
            assertThat(event.path("after").path("client_id").asText()).isEqualTo(client);actualClients.add(client);
            assertThat(value).contains("_redacted_changes","freight_local","source_reference").doesNotContain(marker,privateUpdate,number);
        }
        assertThat(actualClients).containsExactlyInAnyOrder(world.clientId().toString(),otherClient.toString());
        String privateTrail=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_sales_cost_inputs' AND (before->>'client_id'=? OR after->>'client_id'=?)",String.class,world.clientId().toString(),world.clientId().toString());
        assertThat(privateTrail).contains("_redacted_changes","freight_local","source_reference").doesNotContain(marker,privateUpdate,number);
        assertThat(db.queryForList("SELECT action FROM audit_log WHERE target_type='finance_sales_cost_inputs' AND (before->>'client_id'=? OR after->>'client_id'=?) ORDER BY id",String.class,world.clientId().toString(),world.clientId().toString())).containsExactly("insert","update");
        java.util.UUID operation=java.util.UUID.randomUUID();
        db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result)VALUES(?,NULL,?,'PROCUREMENT_AP_POLICY_SAVE',repeat('c',64),jsonb_build_object('requestBody',?::text,'result',?::text,'amount',?::numeric))",operation,world.superAdminUserId(),marker,privateUpdate,number);
        String operationTrail=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_application_operations' AND target_id=?",String.class,operation.toString());
        assertThat(operationTrail).isNotNull().doesNotContain(marker,privateUpdate,number,"requestBody");
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
        var command=new FinanceChartContracts.CreateTarget(java.util.UUID.randomUUID(),equity.version(),"EQUITY","EQUITY",null,"BS_51","PL_PRIOR_ADJUSTMENT");
        var originalReceipt=chart.createTargetCommand(equity.code(),json.valueToTree(command));
        assertThat(chart.createTargetCommand(equity.code(),json.valueToTree(command))).isEqualTo(originalReceipt);
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
        assertThat(chart.createTargetCommand(equity.code(),json.valueToTree(command))).isEqualTo(originalReceipt);
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
        var create=new FinanceChartContracts.CreateTarget(java.util.UUID.randomUUID(),account.version(),"ACCOUNT",null,null,"BS_1",null);
        var created=chart.createTargetCommand("1001",json.valueToTree(create));
        assertThat(chart.createTargetCommand("1001",json.valueToTree(create))).isEqualTo(created);
        account=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThat(account.targets()).hasSize(1);var nativeId=account.targets().getFirst().id();
        assertThat(account.lineKeys()).containsExactly("BS_1");
        var mapping=new FinanceChartContracts.Mapping(java.util.UUID.randomUUID(),account.version(),List.of(nativeId),"BS_1",null,null,null);
        var mapped=chart.mapCommand("1001",json.valueToTree(mapping));
        assertThat(chart.mapCommand("1001",json.valueToTree(mapping))).isEqualTo(mapped);
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
