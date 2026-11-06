package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.*;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real loopback TCP + JWT/security + current SQL; transport1000 is never a product/material result cap. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=periodic-http-fixture-jwt-0123456789-test-only",
        "uten.crypto.pgp-master-key=periodic-http-fixture-pgp-0123456789-test-only",
        "uten.crypto.hmac-key=periodic-http-fixture-hmac-test-only",
        "uten.bootstrap.admin-login=periodic-http-bootstrap","uten.bootstrap.admin-password=PeriodicBootstrap-1!"})
class FinanceContextAndExpenseCompleteSummaryHttpPostgresTest extends CompleteSummaryHttpPostgresSupport {
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.transaction.PlatformTransactionManager metadataTransactions;
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static Path directory;
    @DynamicPropertySource static void database(DynamicPropertyRegistry props) throws Exception {
        PG.start();directory=Files.createTempDirectory("uten-finance-context-http-");
        FixtureDatabaseProperties.bindSameRole(props,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        props.add("uten.storage.local-dir",()->directory.toString());
    }

    @Test void plasticBinContextsCollectAll1001WithoutTruncationAndKeepTheOriginalClosedPeriodMembership() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().substring(0,8),prefix="PLASTIC-CONTEXT-"+tag+"-";
        var world=fixture.seedWorld("plastic-context-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID kilogram=UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES(?,?,?,'千克','使用')",kilogram,800_000_000+new Random().nextInt(90_000_000),"CONTEXT-KG-"+tag);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kilogram);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence,issue_method,periodic_cost_basis)
                SELECT gen_random_uuid(),?||n,'上下文颗粒'||n,'采购','使用',?,10,
                       (SELECT COALESCE(max(code_sequence),0) FROM goods)+n,'PERIODIC','OWN'
                FROM generate_series(1,2) n
                ""","CONTEXT-MATERIAL-"+tag+"-",kilogram);
        UUID material=db.queryForObject("SELECT id FROM goods WHERE code=?",UUID.class,"CONTEXT-MATERIAL-"+tag+"-1");
        UUID secondMaterial=db.queryForObject("SELECT id FROM goods WHERE code=?",UUID.class,"CONTEXT-MATERIAL-"+tag+"-2");
        // Legal metadata at the real schema boundary; no trigger/guard is
        // disabled. This is not a claim of1001 separate stock-close UATs.
        new org.springframework.transaction.support.TransactionTemplate(metadataTransactions).executeWithoutResult(ignored -> {
        db.update("INSERT INTO departments(id,code,name,parent_id,level) SELECT gen_random_uuid(),?||lpad(n::text,5,'0'),'上下文车间'||n,(SELECT id FROM departments WHERE code='DEPT_PROD'),'二级班组' FROM generate_series(1,1004) n","W-"+prefix);
        db.update("""
                INSERT INTO warehouses(id,code,name,status,created_by,parent_id,is_line_side,is_accountable,is_defective,workshop_department_id)
                SELECT gen_random_uuid(),substring(workshop.code from 3),'完整料仓'||right(workshop.code,5),'使用',?,fn_warehouse_root_id(),true,true,false,workshop.id
                FROM departments workshop WHERE workshop.code LIKE ?
                """,world.superAdminUserId(),"W-"+prefix+"%");
        db.update("INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id,opened_by) SELECT workshop_department_id,id,? FROM warehouses WHERE code LIKE ?",world.superAdminUserId(),prefix+"%");
        db.update("""
                INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,periodic_bin_warehouse_id,go_live_date,enabled_by,enabled_at,created_by)
                SELECT workshop_department_id,true,id,DATE '2026-01-01',?,now(),? FROM warehouses WHERE code LIKE ?
                """,world.superAdminUserId(),world.superAdminUserId(),prefix+"%");
        db.update("""
                INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date,end_date,status,created_by)
                SELECT gen_random_uuid(),bin.id,bin.workshop_department_id,1,DATE '2026-01-01',
                  CASE WHEN bin.code=? THEN DATE '2026-01-01' WHEN bin.code=? THEN DATE '2026-02-01' ELSE DATE '2026-01-31' END,
                  CASE WHEN bin.code=? THEN 'COUNTED' ELSE 'CLOSED' END,? FROM warehouses bin WHERE bin.code LIKE ?
                """,prefix+"01001",prefix+"01002",prefix+"01003",world.superAdminUserId(),prefix+"%");
        db.update("""
                INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date,status,created_by)
                SELECT gen_random_uuid(),period.bin_warehouse_id,period.workshop_department_id,2,period.end_date+1,'OPEN',?
                FROM workshop_material_periods period JOIN warehouses bin ON bin.id=period.bin_warehouse_id
                WHERE bin.code LIKE ? AND period.period_no=1
                """,world.superAdminUserId(),prefix+"%");
        db.update("""
                INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id,cost_basis,opening_qty,closing_qty)
                SELECT gen_random_uuid(),period.id,?,?,'OWN',0,0 FROM workshop_material_periods period
                JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code LIKE ? AND bin.code<>? AND period.period_no=1
                """,material,kilogram,prefix+"%",prefix+"01004");
        db.update("""
                INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id,cost_basis,opening_qty,closing_qty)
                SELECT gen_random_uuid(),period.id,?,?,'OWN',0,0 FROM workshop_material_periods period
                JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code=? AND period.period_no=1
                """,secondMaterial,kilogram,prefix+"00001");
        db.update("""
                INSERT INTO workshop_material_period_closes(id,period_id,close_no,status,trigger_kind,closed_by)
                SELECT gen_random_uuid(),period.id,1,'ACTIVE','MANUAL',? FROM workshop_material_periods period
                JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code LIKE ? AND bin.code<>? AND period.period_no=1
                """,world.superAdminUserId(),prefix+"%",prefix+"01003");
        db.update("""
                INSERT INTO workshop_material_close_materials(id,close_id,period_line_id,cost_basis,theory_qty,outcome)
                SELECT gen_random_uuid(),closed.id,line.id,line.cost_basis,0,'NOTHING'
                FROM workshop_material_period_closes closed JOIN workshop_material_periods period ON period.id=closed.period_id
                JOIN warehouses bin ON bin.id=period.bin_warehouse_id JOIN workshop_material_period_lines line ON line.period_id=period.id
                WHERE bin.code LIKE ? AND period.period_no=1
                """,prefix+"%");
        });
        var originalIds=new LinkedHashSet<>(db.queryForList("""
                SELECT DISTINCT bin.id::text FROM v_workshop_material_period_report report JOIN warehouses bin ON bin.id=report.bin_warehouse_id
                WHERE report.close_id IS NOT NULL AND report.end_date BETWEEN DATE '2026-01-01' AND DATE '2026-01-31' ORDER BY bin.id::text
                """,String.class));
        assertThat(originalIds).hasSize(1001);
        UUID reader=fixture.createUserWithPerms(world,"plastic-context-reader-"+tag,"finance_report:view","finance:view:all");
        String login=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,reader),password="ContextRead-"+tag+"-1!";
        db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),reader);
        String token=body(request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",login,"password",password)),null,200)).path("accessToken").asText();
        String sourceBefore=plasticContextBusinessFacts(prefix);
        String base="/api/finance/reports/context/plastic-bins/summaries?dateFrom=2026-01-01&dateTo=2026-01-31&size=1000";
        JsonNode first=body(request("GET",base+"&page=1",null,token,200));
        String revision=first.path("readSnapshotRevision").asText(),authority=first.path("readScopeVersion").asText();
        assertThat(revision).hasSize(64);assertThat(first.path("total").asLong()).isEqualTo(1001);assertThat(first.path("totalPages").asInt()).isEqualTo(2);
        assertThat(first.path("items").size()).isEqualTo(1000);
        var tailResponse=request("GET",base+"&page=2&readSnapshotRevision="+revision,null,token,200);JsonNode tail=body(tailResponse);
        assertThat(tailResponse.headers().firstValue("X-Uten-Read-Scope-Version")).contains(authority);
        assertThat(tail.path("items").size()).isEqualTo(1);assertThat(tail.path("items").get(0).path("code").asText()).isEqualTo(prefix+"01001");
        var actual=new LinkedHashSet<String>();for(var row:first.path("items"))assertThat(actual.add(row.path("id").asText())).isTrue();
        for(var row:tail.path("items"))assertThat(actual.add(row.path("id").asText())).isTrue();assertThat(actual).containsExactlyInAnyOrderElementsOf(originalIds);
        assertThat(plasticContextBusinessFacts(prefix)).isEqualTo(sourceBefore);
        // A real allowed close-state transition changes membership. It cannot
        // be hidden behind an authorization-only stamp or unchanged row count.
        new org.springframework.transaction.support.TransactionTemplate(metadataTransactions).executeWithoutResult(ignored -> {
        db.update("""
                UPDATE workshop_material_period_closes SET status='REVERSED',reversed_by=?,reversed_at=now(),reversal_event_id=?,reverse_reason='local-context-fixture-reverse'
                WHERE period_id=(SELECT period.id FROM workshop_material_periods period JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code=? AND period.period_no=1)
                """,world.superAdminUserId(),UUID.randomUUID(),prefix+"01001");
        db.update("UPDATE workshop_material_periods SET status='COUNTED',row_version=row_version+1 WHERE bin_warehouse_id=(SELECT id FROM warehouses WHERE code=?) AND period_no=1",prefix+"01001");
        });
        assertThat(body(request("GET",base+"&page=2&readSnapshotRevision="+revision,null,token,409)).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        assertThat(body(request("GET",base+"&page=1",null,token,200)).path("total").asLong()).isEqualTo(1000);
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='finance:view:all')",reader);
        request("GET",base+"&page=1",null,token,401);
    }
    private String plasticContextBusinessFacts(String prefix) {
        return db.queryForObject("""
                SELECT md5(concat_ws('|',
                  (SELECT string_agg(to_jsonb(bin)::text,'|' ORDER BY bin.id) FROM warehouses bin WHERE bin.code LIKE ?),
                  (SELECT string_agg(to_jsonb(period)::text,'|' ORDER BY period.id) FROM workshop_material_periods period JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code LIKE ?),
                  (SELECT string_agg(to_jsonb(line)::text,'|' ORDER BY line.id) FROM workshop_material_period_lines line JOIN workshop_material_periods period ON period.id=line.period_id JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code LIKE ?),
                  (SELECT string_agg(to_jsonb(closed)::text,'|' ORDER BY closed.id) FROM workshop_material_period_closes closed JOIN workshop_material_periods period ON period.id=closed.period_id JOIN warehouses bin ON bin.id=period.bin_warehouse_id WHERE bin.code LIKE ?)))
                """,String.class,prefix+"%",prefix+"%",prefix+"%",prefix+"%");
    }

    @Test void everyUnappliedExpenseNoteImportStaysRecoverableBeyondTenWithActorPeriodAndRevisionFences() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld("expense-summary-http-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID reader=fixture.createUserWithPerms(world,"expense-summary-reader-"+tag,
                "finance_report:view","finance:view:all","payment_style:edit");
        String login=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,reader);
        String password="ExpenseSummary-"+tag+"-1!";
        db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),reader);
        String token=body(request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",login,"password",password)),null,200)).path("accessToken").asText();
        // Legal summary-metadata fixture: this test does not claim an uploaded-file/import business UAT.
        db.update("""
                INSERT INTO finance_expense_note_imports(id,actor_id,period,source_name,sha256,
                    storage_provider,storage_key,storage_size,preview,created_at)
                SELECT gen_random_uuid(),?,'2026-01',?||lpad(n::text,4,'0'),
                    md5(?||n::text)||md5(?||n::text),'LOCAL',?||n::text,0,'{}'::jsonb,
                    now()-n*interval '1 second' FROM generate_series(1,1001) n
                """,reader,"完整备注-"+tag+"-",tag,tag,"fixture-summary-not-a-file-"+tag+"-");
        for(int n=0;n<4;n++) {
            UUID id=UUID.randomUUID();boolean applied=n<2;
            db.update("""
                    INSERT INTO finance_expense_note_imports(id,actor_id,period,source_name,sha256,
                        storage_provider,storage_key,storage_size,preview,applied_at,applied_result)
                    VALUES(?,?,?,?,?,'LOCAL',?,0,'{}'::jsonb,?::timestamptz,?::jsonb)
                    """,id,n==2?world.superAdminUserId():reader,n==3?"2026-02":"2026-01",
                    "范围隔离-"+tag+"-"+n,id.toString().replace("-","").repeat(2),
                    "fixture-summary-not-a-file-"+id,applied?"2026-01-31T00:00:00Z":null,
                    applied?json.writeValueAsString(Map.of("importId",id,"state","APPLIED")):null);
        }
        String factsBefore=db.queryForObject("SELECT md5(COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id)::text,'[]')) FROM finance_expense_note_imports fact",String.class);
        String base="/api/finance/expense-analysis/note-imports/summaries?period=2026-01&scope=active&size=1000";
        var firstResponse=request("GET",base+"&page=1",null,token,200);var first=body(firstResponse);
        String revision=first.path("readSnapshotRevision").asText();
        assertThat(first.path("total").asLong()).isEqualTo(1001);assertThat(first.path("totalPages").asInt()).isEqualTo(2);
        assertThat(first.path("items").size()).isEqualTo(1000);
        assertThat(revision).hasSize(64);assertThat(first.path("readDataVersion").asText()).hasSize(64);
        assertThat(firstResponse.headers().firstValue("X-Uten-Read-Scope-Version")).contains(first.path("readScopeVersion").asText());
        var last=body(request("GET",base+"&page=2&readSnapshotRevision="+revision,null,token,200));
        assertThat(last.path("items").size()).isEqualTo(1);
        assertThat(last.path("readSnapshotRevision").asText()).isEqualTo(revision);
        assertThat(last.path("readDataVersion").asText()).isEqualTo(first.path("readDataVersion").asText());
        var ids=new HashSet<String>();
        for(var page:List.of(first,last))for(var row:page.path("items")) {
            assertThat(ids.add(row.path("importId").asText())).isTrue();
            assertThat(row.has("preview")||row.has("storageKey")||row.has("sha256")).isFalse();
            assertThat(row.path("appliedAt").isNull()).isTrue();
        }
        assertThat(ids).hasSize(1001);
        UUID tail=db.queryForObject("SELECT id FROM finance_expense_note_imports WHERE actor_id=? AND period='2026-01' AND source_name=?",UUID.class,reader,"完整备注-"+tag+"-1001");
        assertThat(last.path("items").get(0).path("importId").asText()).isEqualTo(tail.toString());
        assertThat(body(request("GET",base.replace("scope=active","scope=all")+"&page=1",null,token,200)).path("total").asLong()).isEqualTo(1003);
        assertThat(body(request("GET",base.replace("scope=active","scope=history")+"&page=1",null,token,200)).path("total").asLong()).isEqualTo(2);
        assertThat(db.queryForObject("SELECT md5(COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id)::text,'[]')) FROM finance_expense_note_imports fact",String.class)).isEqualTo(factsBefore);
        db.update("UPDATE finance_expense_note_imports SET applied_at=now(),applied_result=?::jsonb WHERE id=?",
                json.writeValueAsString(Map.of("importId",tail,"state","APPLIED")),tail);
        assertThat(body(request("GET",base+"&page=2&readSnapshotRevision="+revision,null,token,409)).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        assertThat(body(request("GET",base+"&page=1",null,token,200)).path("total").asLong()).isEqualTo(1000);
        assertThat(body(request("GET",base.replace("scope=active","scope=history")+"&page=1",null,token,200)).path("total").asLong()).isEqualTo(3);
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='payment_style:edit')",reader);
        request("GET",base+"&page=1",null,token,401);
    }




}
