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
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES(?,?,?,'千克','使用')",kilogram,800_000_000+java.util.concurrent.ThreadLocalRandom.current().nextInt(90_000_000),"CONTEXT-KG-"+tag);
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
                  'COUNTED',? FROM warehouses bin WHERE bin.code LIKE ?
                """,prefix+"01001",prefix+"01002",world.superAdminUserId(),prefix+"%");
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
        // Establish the period lines while COUNTED, then advance the same
        // coherent zero-quantity fact family to CLOSED. The original deferred
        // chain/ledger/period-line/all-material-close assertions remain active.
        db.update("""
                UPDATE workshop_material_periods period SET status='CLOSED',row_version=period.row_version+1
                FROM warehouses bin WHERE bin.id=period.bin_warehouse_id AND bin.code LIKE ? AND period.period_no=1
                  AND EXISTS(SELECT 1 FROM workshop_material_period_closes closed WHERE closed.period_id=period.id AND closed.status='ACTIVE')
                """,prefix+"%");
        });
        var originalIds =new LinkedHashSet<>(db.queryForList("""
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
        var actual=new LinkedHashSet<String>();for(var row:first.path("items")){
            assertThat(actual.add(row.path("id").asText())).isTrue();
        }

        for(var row:tail.path("items")){
            assertThat(actual.add(row.path("id").asText())).isTrue();
        }
        assertThat(actual).containsExactlyInAnyOrderElementsOf(originalIds);
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





    @Test void businessColumnCatalogRetainsAll1001ChineseDefinitionsAndFreshRevision() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().replace("-","").substring(0,10);
        var world=fixture.seedWorld("complete-business-columns-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID reader=fixture.createUserWithPerms(world,"complete-columns-"+tag,"sales_order:view","sales_order:edit");
        String token=completeTailLogin(reader,tag);
        db.update("""
                INSERT INTO business_column_definitions(id,scope,name,normalized_name,value_type,operation,created_by)
                SELECT gen_random_uuid(),'sales_order',?||'完整列'||n,?||'完整列'||n,'TEXT','NONE',?
                FROM generate_series(1,1001) n
                """,tag,tag,reader);
        String path="/api/business-columns/summaries?scope=sales_order&q="+tag+"&size=1000";
        var firstResponse=request("GET",path+"&page=1",null,token,200);var first=body(firstResponse);
        assertThat(first.path("total").asLong()).isEqualTo(1001);assertThat(first.path("items").size()).isEqualTo(1000);
        completeTailProof(firstResponse,first);
        var last=body(request("GET",path+"&page=2&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),null,token,200));
        assertThat(last.path("items").size()).isEqualTo(1);assertThat(last.path("readDataVersion").asText()).isEqualTo(first.path("readDataVersion").asText());
        var ids=new HashSet<String>();for(var page:List.of(first,last))for(var row:page.path("items"))assertThat(ids.add(row.path("id").asText())).isTrue();
        assertThat(ids).hasSize(1001);
        assertThat(body(request("GET","/api/business-columns?scope=sales_order&q="+tag,null,token,200)).size()).isEqualTo(50);
        UUID changed=UUID.fromString(last.path("items").get(0).path("id").asText());
        db.update("UPDATE business_column_definitions SET usage_count=usage_count+1 WHERE id=?",changed);
        assertThat(body(request("GET",path+"&page=2&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),null,token,409)).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='sales_order:view')",reader);
        request("GET",path+"&page=1",null,token,401);
    }

    @Test void platformCatalogHas8193IndependentChoicesWithoutWeakeningTheWriteGraphOrPriceScope() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().replace("-","").substring(0,10);
        var world=fixture.seedWorld("complete-platform-columns-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID reader=fixture.createUserWithPerms(world,"platform-columns-"+tag,"sales_order:view","sales_order:edit");
        String token=completeTailLogin(reader,tag);
        db.update("""
                INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by)
                SELECT gen_random_uuid(),'sales_order',?||'完整字段'||n,?||'完整字段'||n,'TEXT',false,
                    md5(?||n::text)||md5(?||n::text),? FROM generate_series(1,8193) n
                """,tag,tag,tag,tag,reader);
        UUID protectedId=UUID.randomUUID(),deletedId=UUID.randomUUID();
        for(UUID id:List.of(protectedId,deletedId))db.update("""
                INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by)
                VALUES(?,'sales_order',?,?,'TEXT',?,?,?)
                """,id,tag+id,tag+id,id.equals(protectedId),id.toString().replace("-","").repeat(2),reader);
        db.update("INSERT INTO platform_column_definition_deletions(definition_id,deleted_by) VALUES(?,?)",deletedId,reader);
        String path="/api/platform-columns/sales_order/definitions/summaries?q="+tag+"&size=1000";
        var ids=new HashSet<String>();String revision=null,data=null;
        for(int page=1;page<=9;page++){
            var response=request("GET",path+"&page="+page+(revision==null?"":"&readSnapshotRevision="+revision),null,token,200);var value=body(response);
            completeTailProof(response,value);assertThat(value.path("total").asLong()).isEqualTo(8193);assertThat(value.path("totalPages").asInt()).isEqualTo(9);
            if(page==1){revision=value.path("readSnapshotRevision").asText();data=value.path("readDataVersion").asText();}
            assertThat(value.path("readSnapshotRevision").asText()).isEqualTo(revision);assertThat(value.path("readDataVersion").asText()).isEqualTo(data);
            assertThat(value.path("items").size()).isEqualTo(page==9?193:1000);
            for(var row:value.path("items")){assertThat(row.path("priceProtected").asBoolean()).isFalse();assertThat(ids.add(row.path("id").asText())).isTrue();}
        }
        assertThat(ids).hasSize(8193);assertThat(ids).doesNotContain(protectedId.toString(),deletedId.toString());
        // A catalog read must not turn8193 independent choices into one submitted dependency graph.
        assertThat(body(request("GET","/api/platform-columns/sales_order/definitions?q="+tag,null,token,200)).size()).isEqualTo(50);
    }

    @Test void fullBlessingWallKeeps1001SnapshotsMineAndVisibilityWithFiftyRowTransport() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().replace("-","").substring(0,10);
        var world=fixture.seedWorld("complete-wall-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID reader=fixture.createUserWithPerms(world,"wall-reader-"+tag,"notice:read");
        var notice=new com.uten.imp.features.notice.Notice();notice.setTitle("完整祝福墙"+tag);notice.setContent("只读边界夹具");
        notice.setType("birthday");notice.setInteractionMode("bless");notice.setPublisher("fixture");notice.setPublishedAt(java.time.Instant.now());
        notice.setAudienceScope("all");notice.setSubjectEmployeeId(world.employeeId());notice.setSubjectName("夹具主角");
        beans.getBean(com.uten.imp.features.notice.NoticeRepository.class).saveAndFlush(notice);
        // Historical author accounts retain their immutable name snapshots; this is not1001 publication commands.
        String employeePrefix="WALL-AUTHOR-"+tag.toUpperCase(Locale.ROOT)+"-";
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT gen_random_uuid(),?||n,'历史祝福作者'||n,'其他',?,DATE '2025-01-01','active','regular'
                FROM generate_series(1,1000) n
                """,employeePrefix,world.departmentId());
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password)
                SELECT gen_random_uuid(),employee.id,?||substring(employee.code from char_length(?)+1),?,'disabled',true
                FROM employees employee WHERE employee.code LIKE ?
                ""","wall-author-"+tag+"-",employeePrefix,passwords.encode("Fixture-disabled-author-1!"),employeePrefix+"%");
        db.update("""
                INSERT INTO notice_blessings(id,notice_id,user_id,sender_name,content,created_by)
                SELECT gen_random_uuid(),?,id,'历史祝福人'||login_account,'完整祝福'||login_account,id FROM users WHERE login_account LIKE ?
                """,notice.getId(),"wall-author-"+tag+"-%");
        db.update("INSERT INTO notice_blessings(id,notice_id,user_id,sender_name,content,created_by) VALUES(?,?,?,'本人夹具','本人原祝福',?)",UUID.randomUUID(),notice.getId(),reader,reader);
        String token=completeTailLogin(reader,tag);
        String sourceBefore=db.queryForObject("SELECT md5(jsonb_agg(to_jsonb(blessing) ORDER BY id)::text) FROM notice_blessings blessing WHERE notice_id=?",String.class,notice.getId());
        String path="/api/notices/"+notice.getId()+"/blessings/summaries?size=50";String revision=null;var ids=new HashSet<String>();int mine=0;
        for(int page=1;page<=21;page++){
            var response=request("GET",path+"&page="+page+(revision==null?"":"&readSnapshotRevision="+revision),null,token,200);var value=body(response);
            completeTailProof(response,value);assertThat(value.path("total").asLong()).isEqualTo(1001);assertThat(value.path("items").size()).isEqualTo(page==21?1:50);
            if(page==1)revision=value.path("readSnapshotRevision").asText();else assertThat(value.path("readSnapshotRevision").asText()).isEqualTo(revision);
            for(var row:value.path("items")){assertThat(ids.add(row.path("id").asText())).isTrue();if(row.path("mine").asBoolean())mine++;}
        }
        assertThat(ids).hasSize(1001);assertThat(mine).isEqualTo(1);
        assertThat(db.queryForObject("SELECT md5(jsonb_agg(to_jsonb(blessing) ORDER BY id)::text) FROM notice_blessings blessing WHERE notice_id=?",String.class,notice.getId())).isEqualTo(sourceBefore);
        db.update("UPDATE notice_blessings SET content=content||'已改' WHERE notice_id=? AND user_id=?",notice.getId(),reader);
        assertThat(body(request("GET",path+"&page=2&readSnapshotRevision="+revision,null,token,409)).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='notice:read')",reader);
        request("GET",path+"&page=1",null,token,401);
    }

    @Test void supplierGoodsReportKeepsAll51HistoricalGoodsAndTheSameExactWeightedHeader() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().replace("-","").substring(0,10);
        var world=fixture.seedWorld("complete-supplier-loss-"+tag);fixture.loginAs(world.superAdminUserId());
        UUID reader=fixture.createUserWithPerms(world,"loss-reader-"+tag,"subcontract_order:view");String token=completeTailLogin(reader,tag);
        long base=db.queryForObject("SELECT COALESCE(max(code_sequence),0) FROM goods",Long.class);String prefix="LOSS-G-"+tag+"-";
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence)
                SELECT gen_random_uuid(),?||n,'完整损耗货品'||n,'自制','使用',?,1,?+n FROM generate_series(1,51) n
                """,prefix,world.unitId(),base);
        UUID order=UUID.randomUUID();int legacy=500000000+java.util.concurrent.ThreadLocalRandom.current().nextInt(90000000);
        String orderBillNo=beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class)
                .nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.SUB_ORDER);
        // Legal retained-import read fixture, all original archive/identity/quantity guards remain enabled.
        // It does not claim that this read test executed51 real receipt/stock workflows.
        db.update("""
                INSERT INTO subcontract_orders(id,legacy_id,bill_no,bill_date,supplier_id,currency_id,settlement_method_id,exchange_rate,tax_rate,status,created_by)
                VALUES(?,?,?,DATE '2025-01-01',?,?,(SELECT id FROM settlement_methods ORDER BY id LIMIT 1),1,0,1,?)
                """,order,legacy,orderBillNo,world.supplierId(),world.currencyId(),world.superAdminUserId());
        db.update("""
                INSERT INTO subcontract_order_items(id,legacy_id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,received_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                SELECT gen_random_uuid(),?+row_number() OVER(ORDER BY goods.id)::int,?,DATE '2025-01-01',?,row_number() OVER(ORDER BY goods.id)::int,goods.id,?,1,1,1,1,1,1,goods.code,goods.name,'MASTER_AT_APPROVAL'
                FROM goods WHERE code LIKE ?
                """,legacy,orderBillNo,order,world.unitId(),prefix+"%");
        String before=db.queryForObject("SELECT md5(jsonb_agg(to_jsonb(summary) ORDER BY goods_id)::text) FROM v_subcontract_supplier_goods_loss_summary summary WHERE supplier_id=?",String.class,world.supplierId());
        String path="/api/subcontract/short-deliveries/supplier-summary/goods/summaries?supplierId="+world.supplierId()+"&size=50";
        var response=request("GET",path+"&page=1",null,token,200);var first=body(response);completeTailProof(response,first);
        assertThat(first.path("total").asLong()).isEqualTo(51);assertThat(first.path("summary").path("supplierId").asText()).isEqualTo(world.supplierId().toString());
        assertThat(first.path("summary").path("orderedQtyExact").asText()).isEqualTo("51");
        assertThat(first.path("summary").path("byGoods").isEmpty()).isTrue();
        var tail=body(request("GET",path+"&page=2&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),null,token,200));
        assertThat(first.path("items").size()).isEqualTo(50);assertThat(tail.path("items").size()).isEqualTo(1);
        var ids=new HashSet<String>();for(var page:List.of(first,tail))for(var row:page.path("items")){assertThat(ids.add(row.path("goodsId").asText())).isTrue();assertThat(row.path("orderedQtyExact").asText()).isEqualTo("1");}
        assertThat(ids).hasSize(51);
        assertThat(db.queryForObject("SELECT md5(jsonb_agg(to_jsonb(summary) ORDER BY goods_id)::text) FROM v_subcontract_supplier_goods_loss_summary summary WHERE supplier_id=?",String.class,world.supplierId())).isEqualTo(before);
    }

    private String completeTailLogin(UUID reader,String tag) throws Exception {
        String login=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,reader),password="CompleteTail-"+tag+"-1!";
        db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),reader);
        return body(request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",login,"password",password)),null,200)).path("accessToken").asText();
    }
    private static void completeTailProof(java.net.http.HttpResponse<byte[]> response,JsonNode value) {
        assertThat(value.path("readSnapshotRevision").asText()).hasSize(64);assertThat(value.path("readDataVersion").asText()).hasSize(64);
        assertThat(response.headers().firstValue("X-Uten-Read-Scope-Version")).contains(value.path("readScopeVersion").asText());
    }

}
