package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.security.AuthUser;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.math.BigDecimal;
import java.sql.Connection;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.sql.DataSource;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.junit.jupiter.api.Assertions.*;

/** Real public reader, full current schema and actual JDBC accounting; fixture writes stay local. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import({ProductionJdbcMeasurement.Configuration.class,DailyReportDraftClaimsPostgresTest.ProbeConfig.class})
class DailyReportDraftClaimsPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired ProductionDailyReportService reports;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
    @Autowired com.uten.imp.security.SubmitterPrincipalRestorer principals;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    private static final ThreadLocal<Probe> PROBE = new ThreadLocal<>();
    private static final String QUERY="/api/production/daily-reports/draft-claims/query";

    @AfterEach void clear(){PROBE.remove();ProductionJdbcMeasurement.end();SecurityContextHolder.clearContext();}

    @Test void taskSelectionPrecedesHeaderCountAndReadsOnlyLightColumnsWithNoUnrelatedDrafts() throws Exception {
        var c=genuine();login(c.actor());
        for(int i=0;i<101;i++)header(c.world(),(short)0,false);
        item(c.world(),c.report(),99,null,false);
        login(actor(c.world().superAdminUserId(),c.world().employeeId(),Set.of("production_daily_report:view","production_plan:view:all")));
        var probe=new Probe();PROBE.set(probe);var sample=ProductionJdbcMeasurement.begin();
        com.uten.imp.common.web.PageResponse<DailyReportDraftClaimsHeader> selected;
        try{selected=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(c.segment()),1,100));}
        finally{ProductionJdbcMeasurement.end();PROBE.remove();}
        assertEquals(1,selected.getTotal());assertEquals(c.report(),selected.getItems().getFirst().id());
        assertEquals(2,selected.getItems().getFirst().draftClaims().size(),"A matching header retains its other live source rows");
        assertTrue(selected.getItems().getFirst().draftClaims().stream().anyMatch(claim->claim.executionSegmentId()==null&&claim.qty()==null));
        assertEquals(1,probe.projections);assertTrue(sample.logicalStatements<=3,"Actual whole service SQL includes count/header/one child batch: "+sample.logicalStatements);
        assertFalse(probe.headerSelectLists.isEmpty());
        for(String columns:probe.headerSelectLists){
            assertFalse(columns.contains("remark"));assertFalse(columns.contains("supplier_id"));
            assertFalse(columns.contains("warehouse_id"));assertFalse(columns.contains("created_at"));
        }
        var falseAdministrator=queryHttp(c.actor(),List.of(c.segment()));
        assertEquals(403,falseAdministrator.getStatus());
        assertEquals("READ_SCOPE_CHANGED",json.readTree(falseAdministrator.getContentAsByteArray()).path("code").asText());
        var owner=ordinaryOwner(c);
        var foreign=genuine();
        var response=queryHttp(owner,List.of(c.segment(),foreign.segment()));
        assertEquals(200,response.getStatus(),response.getContentAsString());
        var wire=json.readTree(response.getContentAsByteArray());assertEquals(1,wire.path("total").asLong());
        var row=wire.path("items").get(0);assertTrue(row.path("rowVersion").isTextual());
        assertEquals(c.report().toString(),row.path("id").asText());
        assertEquals(1,row.path("draftClaimsVersion").asInt());assertTrue(row.path("draftClaimsFingerprint").asText().matches("[0-9a-f]{64}"));
        assertFalse(row.has("remark"));assertFalse(row.has("workerName"));
    }

    @Test void selectedBodiesAuthorizeEmptyAndForeignInputsAndRejectOversizedScopes() throws Exception {
        var c=genuine();login(c.actor());
        var empty=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(),1,100));
        assertEquals(0,empty.getTotal());assertTrue(empty.getItems().isEmpty());
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        UUID noView=fixture.createUserWithPerms(c.world(),"claims-no-view-"+UUID.randomUUID());
        var noViewActor=restoredActor(noView);
        assertFalse(((AuthUser)noViewActor.getPrincipal()).getPermissions().contains("production_daily_report:view"));
        var response=queryHttp(noViewActor,List.of());assertEquals(403,response.getStatus());
        assertEquals("FORBIDDEN",json.readTree(response.getContentAsByteArray()).path("code").asText());
        UUID foreign=fixture.createUserWithPerms(c.world(),"claims-selected-foreign-"+UUID.randomUUID(),"production_daily_report:view");
        login(actor(foreign,db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,foreign),Set.of("production_daily_report:view")));
        assertEquals(0,reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(c.segment()),1,100)).getTotal());
        login(c.actor());
        List<UUID> tooMany=java.util.stream.IntStream.range(0,101).mapToObj(i->UUID.randomUUID()).toList();
        var rejected=assertThrows(com.uten.imp.common.web.ApiException.class,()->reports.queryDraftClaims(new DailyReportDraftClaimsQuery(tooMany,1,100)));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,rejected.getCode());
        assertThrows(com.uten.imp.common.web.ApiException.class,()->reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(c.segment()),Integer.MAX_VALUE,100)));
    }

    @Test void differentHundredIdBodiesShareOnlyTheSameStableCompleteReportProofAndDetectRawChildChanges() {
        var c=genuine();login(c.actor());
        var first=new ArrayList<UUID>();var second=new ArrayList<UUID>();first.add(c.segment());second.add(c.segment());
        for(int i=1;i<100;i++){first.add(UUID.randomUUID());second.add(UUID.randomUUID());}
        var one=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(first,1,100)).getItems().getFirst();
        var two=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(second,1,100)).getItems().getFirst();
        assertEquals(one.id(),two.id());assertEquals(one.rowVersion(),two.rowVersion());
        assertEquals(one.draftClaimsFingerprint(),two.draftClaimsFingerprint());assertEquals(one.draftClaims(),two.draftClaims());
        db.update("UPDATE production_daily_report_items SET qty=3,output_batch_qty=3 WHERE report_id=?",c.report());
        var changed=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(first,1,100)).getItems().getFirst();
        assertEquals(one.rowVersion(),changed.rowVersion(),"The raw child fixture deliberately does not invent a header version bump");
        assertNotEquals(one.draftClaimsFingerprint(),changed.draftClaimsFingerprint());
        assertEquals("3",changed.draftClaims().getFirst().qty());
    }

    @Test void productionOwnerGrantRevocationAndAbaRetireTheOriginalHttpPublicationProof() throws Exception {
        var c=genuine();
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        UUID viewer=fixture.createUserWithPerms(c.world(),"claims-scope-viewer-"+UUID.randomUUID(),"production_daily_report:view");
        var actor=restoredActor(viewer);assertOrdinaryOwnerScope(actor);
        var before=queryHttp(actor,List.of(c.segment()));assertEquals(200,before.getStatus(),before.getContentAsString());
        assertEquals(0,json.readTree(before.getContentAsByteArray()).path("total").asLong());
        String a=publicationVersion(before);
        fixture.grantDataScope(viewer,"production_plan",c.world().employeeId());
        var granted=queryHttp(actor,List.of(c.segment()));assertEquals(200,granted.getStatus(),granted.getContentAsString());
        assertEquals(1,json.readTree(granted.getContentAsByteArray()).path("total").asLong());String b=publicationVersion(granted);
        assertNotEquals(a,b);
        assertEquals(1,db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='production_plan' AND owner_employee_id=?",viewer,c.world().employeeId()));
        var revoked=queryHttp(actor,List.of(c.segment()));assertEquals(200,revoked.getStatus(),revoked.getContentAsString());
        assertEquals(0,json.readTree(revoked.getContentAsByteArray()).path("total").asLong());String next=publicationVersion(revoked);
        assertNotEquals(a,next);assertNotEquals(b,next);
        fixture.grantDataScope(viewer,"production_plan",c.world().employeeId());
        var again=queryHttp(actor,List.of(c.segment()));assertEquals(200,again.getStatus(),again.getContentAsString());
        assertEquals(1,json.readTree(again.getContentAsByteArray()).path("total").asLong());String aba=publicationVersion(again);
        assertNotEquals(a,aba);assertNotEquals(b,aba);assertNotEquals(next,aba);
        var once=new AtomicBoolean();var probe=new Probe();
        probe.beforeProjection=source->{
            if(!once.compareAndSet(false,true))return;
            try(Connection writer=source.getConnection();var statement=writer.prepareStatement(
                    "DELETE FROM user_data_scopes WHERE user_id=? AND scope='production_plan' AND owner_employee_id=?")){
                assertTrue(writer.getAutoCommit());statement.setObject(1,viewer);statement.setObject(2,c.world().employeeId());
                assertEquals(1,statement.executeUpdate());
            }catch(Exception failure){throw new IllegalStateException(failure);}
        };
        PROBE.set(probe);
        org.springframework.mock.web.MockHttpServletResponse late;
        try{late=queryHttp(actor,List.of(c.segment()));}finally{PROBE.remove();}
        assertTrue(once.get());assertEquals(403,late.getStatus(),late.getContentAsString());
        var rejected=json.readTree(late.getContentAsByteArray());assertEquals("READ_SCOPE_CHANGED",rejected.path("code").asText());
        assertFalse(rejected.has("items"),"A late owner revocation cannot publish the old private projection");
        var finalRead=queryHttp(actor,List.of(c.segment()));assertEquals(200,finalRead.getStatus(),finalRead.getContentAsString());
        assertEquals(0,json.readTree(finalRead.getContentAsByteArray()).path("total").asLong());
        assertNotEquals(aba,publicationVersion(finalRead));
    }

    @Test void onlyDeletedMatchingItemsCannotSelectAHeaderEvenWhenItHasOtherLiveRows() {
        var c=genuine();login(c.actor());
        db.update("UPDATE production_daily_report_items SET is_deleted=TRUE WHERE report_id=?",c.report());
        item(c.world(),c.report(),99,null,false);
        var result=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(c.segment()),1,100));
        assertEquals(0,result.getTotal());assertTrue(result.getItems().isEmpty());
        var header=reports.listWithDraftClaims(filter(),1,100,null,null,false,false).getItems().stream()
                .filter(row->row.getId().equals(c.report())).findFirst().orElseThrow();
        assertEquals(1,header.getDraftClaims().size());assertNull(header.getDraftClaims().getFirst().executionSegmentId());
    }

    @Test void optionalPublicReadKeepsTheOldBodyAndAddsOnlyOneChildProjection() throws Exception {
        var c=genuine();login(c.actor());
        reports.list(filter(),1,100,null,null,false,false);
        reports.listWithDraftClaims(filter(),1,100,null,null,false,false);
        var before=measure(()->reports.list(filter(),1,100,null,null,false,false));
        var probe=new Probe();PROBE.set(probe);
        var after=measure(()->reports.listWithDraftClaims(filter(),1,100,null,null,false,false));
        PROBE.remove();
        assertEquals(before.body().getTotal(),after.body().getTotal());
        assertEquals(before.sample().logicalStatements+1,after.sample().logicalStatements);
        assertEquals(1,probe.projections);assertTrue(probe.readOnly);assertFalse(probe.autoCommit);
        assertEquals(Set.of(Connection.TRANSACTION_REPEATABLE_READ),probe.isolations);
        assertEquals(1,probe.backends.size());assertTrue(probe.headerReads>0);
        var header=after.body().getItems().stream().filter(r->r.getId().equals(c.report())).findFirst().orElseThrow();
        assertEquals(1,header.getDraftClaimsVersion());assertFalse(header.getDraftClaims().isEmpty());
        assertEquals(c.segment(),header.getDraftClaims().getFirst().executionSegmentId());
        assertEquals("4",header.getDraftClaims().getFirst().qty());
        assertFalse(header.getDraftClaims().getFirst().actualSurplus());
        var old=http.perform(get("/api/production/daily-reports").with(authenticated(c.actor()))
                .param("size","100")).andReturn().getResponse();
        assertEquals(200,old.getStatus());assertFalse(json.readTree(old.getContentAsByteArray()).path("items").get(0).has("draftClaims"));
        var fresh=http.perform(get("/api/production/daily-reports").with(authenticated(c.actor()))
                .param("size","100").param("includeDraftClaims","true")).andReturn().getResponse();
        assertEquals(200,fresh.getStatus());assertEquals(1,json.readTree(fresh.getContentAsByteArray()).path("items").get(0).path("draftClaimsVersion").asInt());
    }

    @Test void noViewOrForeignOwnerCannotReadClaimsAndReadAllUsesTheExistingScope() throws Exception {
        var c=genuine();var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        UUID user=fixture.createUserWithPerms(c.world(),"draft-claim-reader-"+UUID.randomUUID(),"production_daily_report:view");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);
        var exact=new DailyReportQueryFilter(db.queryForObject("SELECT bill_no FROM production_daily_reports WHERE id=?",String.class,c.report()),null,null,null,(short)0,null,null);
        var foreign=actor(user,employee,Set.of("production_daily_report:view"));login(foreign);
        assertEquals(0,reports.listWithDraftClaims(exact,1,100,null,null,false,false).getTotal());
        var global=actor(user,employee,Set.of("production_daily_report:view","production_plan:view:all"));login(global);
        assertTrue(reports.listWithDraftClaims(exact,1,100,null,null,false,false).getItems().stream().anyMatch(h->h.getId().equals(c.report())&&!h.getDraftClaims().isEmpty()));
        var denied=actor(user,employee,Set.of());
        var response=http.perform(get("/api/production/daily-reports").with(authenticated(denied))
                .param("includeDraftClaims","true")).andReturn().getResponse();assertEquals(403,response.getStatus());
    }

    @Test void aRealDraftOnPageElevenIsNotTruncatedOrExpandedIntoDetails() {
        var c=genuine();login(c.actor());
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            var rows=new ArrayList<Object[]>();
            for(int i=0;i<1000;i++)rows.add(new Object[]{UUID.randomUUID(),numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_DAILY_REPORT),BusinessTime.today().plusDays(1),c.world().employeeId()});
            db.batchUpdate("INSERT INTO production_daily_reports(id,bill_no,bill_date,maker_id) VALUES(?,?,?,?)",rows);
        });
        int page=1,pages=1,total=0,projections=0;boolean tail=false;
        long globalStarted=System.nanoTime();
        do {
            var probe=new Probe();PROBE.set(probe);
            var response=reports.listWithDraftClaims(filter(),page,100,null,null,false,false);PROBE.remove();
            assertEquals(100,response.getSize());assertEquals(1001,response.getTotal());
            pages=response.getTotalPages();total+=response.getItems().size();projections+=probe.projections;
            if(response.getItems().stream().anyMatch(h->h.getId().equals(c.report())&&!h.getDraftClaims().isEmpty())){assertEquals(11,page);tail=true;}
            page++;
        } while(page<=pages);
        assertEquals(11,pages);assertEquals(1001,total);assertTrue(tail);assertEquals(11,projections);
        double globalMillis=(System.nanoTime()-globalStarted)/1_000_000.0;
        long selectedStarted=System.nanoTime();
        var selected=reports.queryDraftClaims(new DailyReportDraftClaimsQuery(List.of(c.segment()),1,100));
        double selectedMillis=(System.nanoTime()-selectedStarted)/1_000_000.0;
        assertEquals(1,selected.getTotal());assertEquals(c.report(),selected.getItems().getFirst().id());
        try {
            var evidence=java.nio.file.Path.of("build/loading-validation/daily-report-draft-claims/current-task-service-comparison.json");
            java.nio.file.Files.createDirectories(evidence.getParent());
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.toFile(),java.util.Map.of(
                    "scope","Real public service, 1001 current draft headers under the same original owner, one accepted task segment; isolated structural fixture, no production SLA",
                    "activeDraftHeaders",1001,"acceptedTaskSegments",1,"globalHeaderBatches",11,"selectedHeaderBatches",1,
                    "globalReturnedHeaders",1001,"selectedReturnedHeaders",1,"globalPublicServiceMillis",globalMillis,
                    "selectedPublicServiceMillis",selectedMillis,"sameRealDraftClaimRetained",true));
        } catch(java.io.IOException failure){throw new IllegalStateException(failure);}
    }

    @Test void nullableExactSurplusAndCurrentDeletedStatusFollowTheOriginalReadContract() {
        var c=genuine(true);login(c.actor());
        UUID draft=header(c.world(),(short)0,false),approved=header(c.world(),(short)1,false),deleted=header(c.world(),(short)0,true);
        item(c.world(),draft,1,null,false);item(c.world(),draft,2,new BigDecimal("90071992547409.1234"),false);
        item(c.world(),approved,1,BigDecimal.ONE,false);item(c.world(),deleted,1,BigDecimal.ONE,false);
        var result=reports.listWithDraftClaims(new DailyReportQueryFilter(null,null,null,null,null,null,null),1,100,null,null,true,false);
        var byId=result.getItems().stream().collect(java.util.stream.Collectors.toMap(DailyReportListItem::getId,h->h));
        var claims=byId.get(draft).getDraftClaims();assertEquals(2,claims.size());
        assertNull(claims.getFirst().executionSegmentId());assertNull(claims.getFirst().qty());
        assertEquals("90071992547409.1234",claims.get(1).qty());assertFalse(claims.get(1).actualSurplus());
        assertTrue(byId.get(c.report()).getDraftClaims().stream().anyMatch(DailyReportDraftClaim::actualSurplus));
        assertTrue(byId.get(approved).getDraftClaims().isEmpty());assertTrue(byId.get(deleted).getDraftClaims().isEmpty());
        assertTrue(byId.get(deleted).isDeleted());
        assertFalse(reports.listWithDraftClaims(filter(),1,100,null,null,false,false).getItems().stream().anyMatch(h->h.getId().equals(approved)||h.getId().equals(deleted)));
    }

    @Test void committedChildRemovalBetweenHeaderAndProjectionDoesNotMixSnapshots() {
        var c=genuine();login(c.actor());var probe=new Probe();var once=new AtomicBoolean();
        probe.beforeProjection=(source)->{
            if(!once.compareAndSet(false,true))return;
            try(Connection writer=source.getConnection();var statement=writer.prepareStatement("DELETE FROM production_daily_report_items WHERE report_id=?")){
                statement.setObject(1,c.report());assertTrue(statement.executeUpdate()>0);
            }catch(Exception failure){throw new IllegalStateException(failure);}
        };PROBE.set(probe);
        var response=reports.listWithDraftClaims(filter(),1,100,null,null,false,false);PROBE.remove();
        assertTrue(once.get());assertFalse(response.getItems().stream().filter(h->h.getId().equals(c.report())).findFirst().orElseThrow().getDraftClaims().isEmpty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=?",Integer.class,c.report()));
        assertTrue(reports.listWithDraftClaims(filter(),1,100,null,null,false,false).getItems().stream().filter(h->h.getId().equals(c.report())).findFirst().orElseThrow().getDraftClaims().isEmpty());
    }

    private Case genuine(){return genuine(false);}
    private Case genuine(boolean surplus){
        var workshop=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(workshop);workshop.prepare();
        Object task=ReflectionTestUtils.invokeMethod(workshop,"createStartedTask","draft-claims-"+UUID.randomUUID(),false,"10");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");
        @SuppressWarnings("unchecked") List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(workshop,"sources",task);
        if(surplus)ReflectionTestUtils.invokeMethod(workshop,"approveRate",task,"0.25");
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(workshop,"reportRequest",task,sources.getFirst(),surplus?"11":"4",surplus?"10":"4");
        UUID id=reports.create(request).getId();
        return new Case(world,id,sources.getFirst().executionSegmentId(),actor(world.superAdminUserId(),world.employeeId(),Set.of("production_daily_report:view")));
    }
    private UUID header(FullChainEndToEndTest.World world,short status,boolean deleted){
        UUID id=UUID.randomUUID();db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,maker_id,status,is_deleted) VALUES(?,?,?,?,?,?)",id,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_DAILY_REPORT),BusinessTime.today(),world.employeeId(),status,deleted);return id;
    }
    private void item(FullChainEndToEndTest.World world,UUID report,int line,BigDecimal qty,boolean surplus){
        assertEquals(1,db.update("""
                INSERT INTO production_daily_report_items(id,report_id,line_no,goods_id,unit_id,unit_rate,
                    qty,is_actual_surplus,bill_no,bill_date)
                SELECT ?,report.id,?,?,?,1,?,?,report.bill_no,report.bill_date
                FROM production_daily_reports report WHERE report.id=?
                """,UUID.randomUUID(),line,world.goodsA(),world.unitId(),qty,surplus,report));
    }
    private DailyReportQueryFilter filter(){return new DailyReportQueryFilter(null,null,null,null,(short)0,null,null);}
    private Authentication restoredActor(UUID user){
        var stamps=principals.currentStamps(user).orElseThrow();
        var principal=principals.restore(user,stamps.authVersion(),stamps.authorizationEpoch());
        return new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities());
    }
    private Authentication ordinaryOwner(Case c){
        assertEquals(1,db.update("UPDATE users SET is_super_admin=false WHERE id=?",c.world().superAdminUserId()));
        assertEquals(1,db.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,'grant' FROM permissions WHERE code='production_daily_report:view'
                """,c.world().superAdminUserId()));
        var actor=restoredActor(c.world().superAdminUserId());assertOrdinaryOwnerScope(actor);
        assertEquals(c.world().employeeId(),((AuthUser)actor.getPrincipal()).getEmployeeId());
        return actor;
    }
    private void assertOrdinaryOwnerScope(Authentication actor){
        var principal=(AuthUser)actor.getPrincipal();assertFalse(principal.isSuperAdmin());
        assertTrue(principal.getPermissions().contains("production_daily_report:view"));
        for(String bypass:Set.of("production_plan:view:all","production_daily_report:approve","production_daily_report:reverse"))
            assertFalse(principal.getPermissions().contains(bypass),"The ordinary-reader fixture cannot bypass maker scope: "+bypass);
    }
    private org.springframework.mock.web.MockHttpServletResponse queryHttp(Authentication actor,List<UUID> ids)throws Exception{
        return http.perform(post(QUERY).with(authenticated(actor)).contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(new DailyReportDraftClaimsQuery(ids,1,100)))).andReturn().getResponse();
    }
    private String publicationVersion(org.springframework.mock.web.MockHttpServletResponse response){
        String version=response.getHeader("X-Uten-Read-Scope-Version");assertNotNull(version);assertTrue(version.matches("[0-9a-f]{64}"));return version;
    }
    private Authentication actor(UUID user,UUID employee,Set<String> permissions){var principal=new AuthUser(user,employee,"draft-claim-reader",permissions,false,true,false);return new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities());}
    private void login(Authentication actor){SecurityContextHolder.getContext().setAuthentication(actor);}
    private record Case(FullChainEndToEndTest.World world,UUID report,UUID segment,Authentication actor){}
    private record Measured(com.uten.imp.common.web.PageResponse<DailyReportListItem> body,ProductionJdbcMeasurement.Sample sample){}
    private Measured measure(java.util.function.Supplier<com.uten.imp.common.web.PageResponse<DailyReportListItem>> read){var sample=ProductionJdbcMeasurement.begin();try{return new Measured(read.get(),sample);}finally{ProductionJdbcMeasurement.end();}}

    private static class Probe{
        int projections,headerReads;boolean readOnly=true,autoCommit=false;
        final Set<Integer> backends=new java.util.HashSet<>(),isolations=new java.util.HashSet<>();
        final List<String> headerSelectLists=new ArrayList<>();
        java.util.function.Consumer<DataSource> beforeProjection;
    }
    @TestConfiguration(proxyBeanMethods=false)
    static class ProbeConfig{
        @Bean static BeanPostProcessor draftClaimProbe(){return new BeanPostProcessor(){
            @Override public Object postProcessAfterInitialization(Object bean,String name){
                if(!(bean instanceof DataSource source))return bean;
                return new DelegatingDataSource(source){
                    @Override public Connection getConnection()throws java.sql.SQLException{return observe(super.getConnection(),source);}
                    @Override public Connection getConnection(String user,String password)throws java.sql.SQLException{return observe(super.getConnection(user,password),source);}
                };
            }
        };}
        private static Connection observe(Connection target,DataSource source){
            return (Connection)Proxy.newProxyInstance(Connection.class.getClassLoader(),new Class<?>[]{Connection.class},(proxy,method,args)->{
                Probe probe=PROBE.get();
                if(probe!=null&&method.getName().startsWith("prepare")&&args!=null&&args[0] instanceof String sql&&sql.contains("production_daily_reports")){
                    probe.backends.add(target.unwrap(org.postgresql.PGConnection.class).getBackendPID());
                    probe.isolations.add(target.getTransactionIsolation());probe.readOnly&=target.isReadOnly();probe.autoCommit|=target.getAutoCommit();
                    if(sql.contains("SELECT item.report_id, item.execution_segment_id")){
                        probe.projections++;if(probe.beforeProjection!=null)probe.beforeProjection.accept(source);
                    }else {
                        probe.headerReads++;
                        String normalized=sql.replaceAll("\\s+"," ").toLowerCase(java.util.Locale.ROOT);
                        int from=normalized.indexOf(" from ");
                        if(normalized.startsWith("select ")&&!normalized.startsWith("select count(")&&from>0
                                &&!normalized.substring(0,from).contains("fn_imported_business_document(")) {
                            probe.headerSelectLists.add(normalized.substring(0,from));
                        }
                    }
                }
                try{return method.invoke(target,args);}catch(InvocationTargetException failure){throw failure.getCause();}
            });
        }
    }
}
