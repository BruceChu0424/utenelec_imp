package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportApproveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real PostgreSQL + normal service edits + complete HTTP security chain. No mocked business services. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000", "uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class DailyReportApprovalV2PostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_review_v2").withUsername("uten").withPassword("uten");
    private static final UUID LEGACY_ACTOR = UUID.randomUUID(), LEGACY_REPORT = UUID.randomUUID();
    private static String legacyXmin;
    private static String migrationFrom;
    private static final String LEGACY_KEY = "v768-history-key";
    private static final String LEGACY_HASH = "1".repeat(64);

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws Exception {
        POSTGRES.start();
        var available = Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load();
        var target = org.flywaydb.core.api.MigrationVersion.fromVersion("769");
        migrationFrom = java.util.Arrays.stream(available.info().all())
                .map(org.flywaydb.core.api.MigrationInfo::getVersion)
                .filter(java.util.Objects::nonNull).filter(version -> version.compareTo(target) < 0)
                .max(java.util.Comparator.naturalOrder()).orElseThrow().getVersion();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target(migrationFrom).load().migrate();
        System.out.println("DAILY-REPORT-REVIEW-MIGRATION " + migrationFrom + " -> 769");
        try (Connection c = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            UUID department = UUID.randomUUID(), employee = UUID.randomUUID();
            update(c, "INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')", department, "V768-HISTORY", "V768 history");
            update(c, "INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",
                    employee, "V768-HISTORY-E", "V768 history actor", department);
            update(c, "INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",
                    LEGACY_ACTOR, employee, "v768-history-user");
            // Pre-Boot historical fixture still obeys the registered SR/date/six-digit contract.
            update(c, "INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,?,DATE '2020-01-01',0,?)", LEGACY_REPORT, "SR20200101000001", employee);
            update(c, "INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind) VALUES(?,?,?,?,?,'APPROVE')",
                    LEGACY_ACTOR, LEGACY_KEY, LEGACY_HASH, LEGACY_REPORT, LEGACY_ACTOR);
            try (PreparedStatement statement = c.prepareStatement("SELECT xmin::text FROM production_daily_report_commands WHERE actor_user_id=? AND idempotency_key=?")) {
                statement.setObject(1, LEGACY_ACTOR); statement.setString(2, LEGACY_KEY);
                try (ResultSet row = statement.executeQuery()) { assertTrue(row.next()); legacyXmin = row.getString(1); }
            }
        }
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDailyReportService reports;
    @Autowired DocNumberService numbers;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;

    @BeforeEach void prepare() {
        fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture);
        world = fixture.seedWorld("review-v2-" + UUID.randomUUID().toString().substring(0, 8));
        fixture.loginAs(world.superAdminUserId());
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void migrationRetainsNullHistoricalMetadataAndRejectsInventedVersionZero() {
        Map<String,Object> old = db.queryForMap("SELECT request_hash,approval_protocol_version,reviewed_row_version,xmin::text AS row_xmin FROM production_daily_report_commands WHERE actor_user_id=? AND idempotency_key=?", LEGACY_ACTOR, LEGACY_KEY);
        assertEquals(LEGACY_HASH, old.get("request_hash")); assertEquals(legacyXmin, old.get("row_xmin"));
        assertNull(old.get("approval_protocol_version")); assertNull(old.get("reviewed_row_version"));
        for (Object[] pair : List.of(new Object[]{null,0L}, new Object[]{2,null}, new Object[]{2,-1L}, new Object[]{1,0L}, new Object[]{3,0L})) {
            UUID id = header(world.employeeId());
            assertThrows(DataIntegrityViolationException.class, () -> command(id, world.superAdminUserId(), key(), pair[0], pair[1]));
        }
        assertThrows(Exception.class, () -> db.update("UPDATE production_daily_report_commands SET reviewed_row_version=0 WHERE actor_user_id=? AND idempotency_key=?", LEGACY_ACTOR, LEGACY_KEY));
        assertNull(db.queryForObject("SELECT reviewed_row_version FROM production_daily_report_commands WHERE actor_user_id=? AND idempotency_key=?", Long.class, LEGACY_ACTOR, LEGACY_KEY));
    }

    @Test void realRowLockWaitSeesConcurrentVersionAdvanceAndRejectsBeforeApprovalWrites() throws Exception {
        UUID id = header(world.employeeId()); String key = key(); Authentication actor = auth(world.superAdminUserId());
        try (var executor = Executors.newSingleThreadExecutor(); Connection writer = db.getDataSource().getConnection()) {
            writer.setAutoCommit(false);
            int writerPid;
            try (var q=writer.prepareStatement("SELECT pg_backend_pid()" );var row=q.executeQuery()) { assertTrue(row.next()); writerPid=row.getInt(1); }
            try (var q=writer.prepareStatement("SELECT id FROM production_daily_reports WHERE id=? FOR UPDATE")) { q.setObject(1,id);q.executeQuery().close(); }
            var waiting = executor.submit(() -> request(post(path(id)+"/approve"), actor, v2(key,0L),409));
            boolean blocked=false;
            for(int attempt=0;attempt<100&&!blocked;attempt++) {
                blocked=Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE ? = ANY(pg_blocking_pids(pid)))",Boolean.class,writerPid));
                if(!blocked) Thread.sleep(25);
            }
            assertTrue(blocked,"the real approval transaction must reach PostgreSQL's row lock wait");
            update(writer,"UPDATE production_daily_reports SET remark='concurrent reviewed change',row_version=row_version+1 WHERE id=?",id);
            writer.commit();
            JsonNode rejected=body(waiting.get(15,TimeUnit.SECONDS));
            assertEquals("DAILY_REPORT_REVIEW_VERSION_CONFLICT",rejected.path("code").asText());
        }
        assertEquals(1L,db.queryForObject("SELECT row_version FROM production_daily_reports WHERE id=?",Long.class,id));
        assertNoApproval(id);
    }

    @Test void normalQuantityMaterialAndParticipantEditsAdvanceVersionAndRejectTheOldReview() throws Exception {
        WorkshopPublicSurplusEndToEndTest workshop = new WorkshopPublicSurplusEndToEndTest(); beans.autowireBean(workshop); workshop.prepare();
        Object task = ReflectionTestUtils.invokeMethod(workshop,"createStartedTask","review-fields-"+UUID.randomUUID().toString().substring(0,8),false,"10");
        var taskWorld = (FullChainEndToEndTest.World) ReflectionTestUtils.invokeMethod(task,"world");
        @SuppressWarnings("unchecked") var sources=(List<ReportablePlanLine>)ReflectionTestUtils.invokeMethod(workshop,"sources",task);
        DailyReportSaveRequest input=ReflectionTestUtils.invokeMethod(workshop,"reportRequest",task,sources.getFirst(),"4","4");
        var created=reports.create(input); UUID id=created.getId(); long oldVersion=created.getRowVersion();
        Authentication actor=auth(taskWorld.superAdminUserId());
        Object secondAssignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","review-worker-"+UUID.randomUUID());
        UUID secondWorker=ReflectionTestUtils.invokeMethod(secondAssignment,"workerId");
        for(int change=0;change<3;change++) {
            fixture.loginAs(taskWorld.superAdminUserId()); input.setExpectedVersion(oldVersion);
            if(change==0) { input.getItems().getFirst().setQty(new BigDecimal("3")); input.getMaterialLines().getFirst().setQtyBase(new BigDecimal("3")); }
            if(change==1) input.getMaterialLines().getFirst().setQtyBase(new BigDecimal("2.5"));
            if(change==2) input.setWorkerIds(List.of(input.getWorkerIds().getFirst(),secondWorker));
            var edited=reports.update(id,input);
            assertTrue(edited.getRowVersion()>oldVersion);
            assertEquals("DAILY_REPORT_REVIEW_VERSION_CONFLICT",body(request(post(path(id)+"/approve"),actor,v2(key(),oldVersion),409)).path("code").asText());
            assertNoApproval(id); oldVersion=edited.getRowVersion();
        }
    }

    @Test void normalDestinationEditAlsoRejectsTheOriginalSeenVersion() throws Exception {
        WorkshopDirectTransferBatchEndToEndTest transfer=new WorkshopDirectTransferBatchEndToEndTest();beans.autowireBean(transfer);transfer.prepare();
        Object task=ReflectionTestUtils.invokeMethod(transfer,"create","review-route-"+UUID.randomUUID().toString().substring(0,8),false);
        var taskWorld=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(task,"world");
        UUID workerUser=ReflectionTestUtils.invokeMethod(task,"workerUser");fixture.loginAs(workerUser);
        UUID segment=ReflectionTestUtils.invokeMethod(task,"childSegment");
        var input=new DailyReportSaveRequest();input.setIdempotencyKey(key());input.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        input.setWarehouseId(ReflectionTestUtils.invokeMethod(task,"leaf")); input.setDepartmentId(ReflectionTestUtils.invokeMethod(task,"workshop"));
        input.setWorkerIds(List.of((UUID)ReflectionTestUtils.invokeMethod(task,"worker")));
        var line=new DailyReportItemLine();line.setLineNo(1);line.setExecutionSegmentId(segment);
        line.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        line.setGoodsId(ReflectionTestUtils.invokeMethod(task,"child"));line.setUnitId(taskWorld.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("4"));
        line.setAllocations(List.of(DailyReportOutputAllocationLine.warehouse(line.getQty())));input.setItems(List.of(line));
        @SuppressWarnings("unchecked") var usage=(List<DailyReportMaterialUsageLine>)ReflectionTestUtils.invokeMethod(transfer,"directInputUse",task,line.getQty());input.setMaterialLines(usage);
        var reviewed=reports.create(input); input.setExpectedVersion(reviewed.getRowVersion());
        line.setAllocations(List.of(DailyReportOutputAllocationLine.direct(ReflectionTestUtils.invokeMethod(transfer,"parentDemand",task),line.getQty())));
        var changed=reports.update(reviewed.getId(),input);assertTrue(changed.getRowVersion()>reviewed.getRowVersion());
        var result=body(request(post(path(reviewed.getId())+"/approve"),auth(taskWorld.superAdminUserId()),v2(key(),reviewed.getRowVersion()),409));
        assertEquals("DAILY_REPORT_REVIEW_VERSION_CONFLICT",result.path("code").asText());assertNoApproval(reviewed.getId());
    }

    @Test void successfulV2HttpReplayKeepsOriginalReviewAfterVersionAndStatusAdvance() throws Exception {
        WorkshopPublicSurplusEndToEndTest workshop=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(workshop);workshop.prepare();
        Object task=ReflectionTestUtils.invokeMethod(workshop,"createStartedTask","review-replay-"+UUID.randomUUID().toString().substring(0,8),false,"10");
        var taskWorld=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(task,"world");
        @SuppressWarnings("unchecked") var sources=(List<ReportablePlanLine>)ReflectionTestUtils.invokeMethod(workshop,"sources",task);
        DailyReportSaveRequest input=ReflectionTestUtils.invokeMethod(workshop,"reportRequest",task,sources.getFirst(),"4","4");
        var detail=reports.create(input);String key=key();Authentication actor=auth(taskWorld.superAdminUserId());var command=v2(key,detail.getRowVersion());
        JsonNode first=body(request(post(path(detail.getId())+"/approve"),actor,command,200));
        assertEquals(2,first.path("approvalCommandVersion").asInt());assertEquals(2,first.path("approvalReceipt").path("commandVersion").asInt());
        assertEquals(detail.getRowVersion(),first.path("approvalReceipt").path("reviewedVersion").asLong());
        assertFalse(first.path("approvalReceipt").path("replay").asBoolean());
        fixture.loginAs(taskWorld.superAdminUserId());reports.reverse(detail.getId());
        long version=db.queryForObject("SELECT row_version FROM production_daily_reports WHERE id=?",Long.class,detail.getId());
        JsonNode replay=body(request(post(path(detail.getId())+"/approve"),actor,command,200));
        assertEquals(-1,replay.path("status").asInt());assertEquals(version,replay.path("rowVersion").asLong());
        assertTrue(replay.path("approvalReceipt").path("replay").asBoolean());
        request(post(path(detail.getId())+"/approve"),actor,v2(key,detail.getRowVersion()+1),409);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",Integer.class,detail.getId()));
    }

    @Test void receiptSecurityUsesCurrentViewObjectScopeAndActorKeyAfterApproveIsRevoked() throws Exception {
        UUID owner=user("production_daily_report:view","production_daily_report:approve");UUID ownerEmployee=employee(owner);
        UUID id=header(ownerEmployee);String key=key();command(id,owner,key,null,null);
        Authentication prior=auth(owner);
        assertTrue(prior.getAuthorities().stream().anyMatch(a->a.getAuthority().equals("production_daily_report:approve")));
        JsonNode legacyConflict=body(request(post(path(id)+"/approve"),prior,v2(key,0L),409));
        assertEquals("DAILY_REPORT_LEGACY_APPROVAL_RECEIPT",legacyConflict.path("code").asText());
        var legacyRequest=new DailyReportApproveRequest();legacyRequest.setIdempotencyKey(key);
        JsonNode legacyReplay=body(request(post(path(id)+"/approve"),prior,legacyRequest,200));
        assertEquals("LEGACY_UNVERSIONED",legacyReplay.path("approvalReceipt").path("reviewProtection").asText());
        assertNull(db.queryForObject("SELECT reviewed_row_version FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",Long.class,id));
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='production_daily_report:approve')",owner);
        Authentication current=auth(owner);
        assertFalse(current.getAuthorities().stream().anyMatch(a->a.getAuthority().equals("production_daily_report:approve")));
        JsonNode receipt=body(request(get(path(id)+"/approval-receipt").param("idempotencyKey",key),current,null,200));
        assertEquals("CONFIRMED",receipt.path("status").asText());assertEquals("LEGACY_UNVERSIONED",receipt.path("receipt").path("reviewProtection").asText());
        assertTrue(receipt.path("receipt").path("reviewedVersion").isNull()||receipt.path("receipt").path("reviewedVersion").isMissingNode());
        request(post(path(id)+"/approve"),current,v2(key,0L),403);
        request(get(path(id)+"/approval-receipt").param("idempotencyKey",key),auth(user()),null,403);
        request(get(path(id)+"/approval-receipt").param("idempotencyKey",key),auth(user("production_daily_report:view")),null,404);
        Authentication readableOther=auth(user("production_daily_report:view","production_plan:view:all"));
        for(String probed:List.of(key,key())) {
            JsonNode absent=body(request(get(path(id)+"/approval-receipt").param("idempotencyKey",probed),readableOther,null,200));
            assertEquals("UNCONFIRMED",absent.path("status").asText());assertFalse(absent.hasNonNull("receipt"));
        }
        request(post(path(id)+"/approve"),auth(world.superAdminUserId()),v2(key(),null),422);
    }

    @Test void busyAndAbsentReceiptQueriesNeverCreateAnApprovalOrInventFailure() throws Exception {
        UUID id=header(world.employeeId());String key=key();Authentication actor=auth(world.superAdminUserId());
        try(Connection owner=db.getDataSource().getConnection()) {
            owner.setAutoCommit(false);
            try(var q=owner.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?,CAST(409 AS bigint)))")) {
                q.setString(1,"PRODUCTION-DAILY-REPORT-APPROVE:"+world.superAdminUserId()+":"+key);q.executeQuery().close();
            }
            assertEquals("PENDING",body(request(get(path(id)+"/approval-receipt").param("idempotencyKey",key),actor,null,200)).path("status").asText());
            owner.rollback();
        }
        assertEquals("UNCONFIRMED",body(request(get(path(id)+"/approval-receipt").param("idempotencyKey",key),actor,null,200)).path("status").asText());
        assertNoApproval(id);
    }

    private UUID header(UUID maker) {UUID id=UUID.randomUUID();db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,?,CURRENT_DATE,0,?)",id,numbers.nextNumber(DocNumberPrefix.PRODUCTION_DAILY_REPORT),maker);return id;}
    private UUID user(String... permissions) {
        UUID department=UUID.randomUUID(),employee=UUID.randomUUID(),user=UUID.randomUUID();String tag=user.toString().substring(0,10);
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"RV2-D-"+tag,"V2独立部门");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"RV2-E-"+tag,"V2审核员",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",user,employee,"rv2-"+tag);
        for(String permission:permissions) assertEquals(1,db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=?",user,permission));
        return user;
    }
    private UUID employee(UUID user){return db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);}
    private void command(UUID report,UUID actor,String key,Object protocol,Object version) {
        db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version) VALUES(?,?,?,?,?,'APPROVE',?,?)",
                actor,key,CanonicalFingerprint.sha256(List.of("PRODUCTION-DAILY-REPORT-APPROVE-V1","report:"+report)),report,actor,protocol,version);
    }
    private void assertNoApproval(UUID id) {
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",Integer.class,id));
        assertEquals((short)0,db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?",Short.class,id));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_settlement_events WHERE daily_report_id=?",Integer.class,id));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=?",Integer.class,id));
    }
    private Authentication auth(UUID user){fixture.loginAs(user);Authentication result=SecurityContextHolder.getContext().getAuthentication();SecurityContextHolder.clearContext();return result;}
    private static DailyReportApproveRequest v2(String key,Long version){var request=new DailyReportApproveRequest();request.setIdempotencyKey(key);request.setCommandVersion(2);request.setExpectedVersion(version);return request;}
    private static String key(){return "review-v2-"+UUID.randomUUID();}
    private static String path(UUID id){return "/api/production/daily-reports/"+id;}
    private JsonNode body(MvcResult response)throws Exception{return json.readTree(response.getResponse().getContentAsByteArray());}
    private MvcResult request(MockHttpServletRequestBuilder request,Authentication actor,Object body,int expected)throws Exception {
        request.with(authentication(actor));if(body!=null)request.contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsBytes(body));
        MvcResult result=http.perform(request).andReturn();assertEquals(expected,result.getResponse().getStatus(),result.getResponse().getContentAsString());return result;
    }
    private static void update(Connection c,String sql,Object...args)throws Exception {try(var statement=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.executeUpdate();}}
}
