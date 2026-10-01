package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Actual CREATE followed by a pure original-result HTTP observation, with no mocked business writer. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
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
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class DailyReportCreateReceiptPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r) { FullChainEndToEndTest.registerDataSource(r); }
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDailyReportService reports;
    @Autowired com.uten.imp.common.platformcolumns.PlatformColumnService fields;
    @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
    private static final String PATH="/api/production/daily-reports/create-receipt";
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void lostCreateResponseResolvesOriginalBodyAfterWriteRightsAreRevokedWithoutBusinessChanges() throws Exception {
        var c=create(); var before=facts(c.id());
        JsonNode result=resolveBody(c.originalBody(), reader(c), 200);
        assertEquals("COMMITTED",result.path("status").asText());
        assertEquals(c.id().toString(),result.path("reportId").asText());
        assertEquals(c.request().getIdempotencyKey(),result.path("idempotencyKey").asText());
        assertEquals(64,result.path("requestHash").asText().length());
        assertEquals(1,result.path("fullPayloadVersion").asInt());
        assertEquals(64,result.path("fullPayloadHash").asText().length());
        assertTrue(result.path("detail").path("historyReadOnly").asBoolean());
        assertEquals(0,result.path("detail").path("allowedActions").size());
        assertEquals(before,facts(c.id()));
        assertEquals("COMMITTED",resolveBody(c.originalBody(),reader(c),200).path("status").asText());
        assertEquals(before,facts(c.id()));
    }

    @Test void deletedOriginalResolvesReadOnlyAndCannotCreateAReplacement() throws Exception {
        var c=create(); login(c.world().superAdminUserId()); reports.delete(c.id());
        var before=facts(c.id());
        JsonNode result=resolve(c.request(),reader(c),200);
        assertEquals("COMMITTED",result.path("status").asText());
        assertTrue(result.path("detail").path("deleted").asBoolean());
        assertTrue(result.path("detail").path("historyReadOnly").asBoolean());
        assertEquals(0,result.path("detail").path("allowedActions").size());
        assertEquals(before,facts(c.id()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=?",Integer.class,c.id()));
    }

    @Test void sameKeyDifferentBodyConflictsWithoutReevaluatingOrWritingTheDraft() throws Exception {
        var c=create(); var before=facts(c.id());
        c.request().getItems().getFirst().setQty(new BigDecimal("3"));
        resolve(c.request(),reader(c),409);
        assertEquals(before,facts(c.id()));
    }

    @Test void aDifferentActorCannotClaimTheReceiptEvenWithGlobalObjectReadPermission() throws Exception {
        var c=create();
        FullChainEndToEndTest fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
        UUID other=fixture.createUserWithPerms(c.world(),"create-receipt-other-"+UUID.randomUUID(),
                "production_daily_report:view","production_plan:view:all");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);
        var before=facts(c.id());
        var actor=auth(other,employee,Set.of("production_daily_report:view","production_plan:view:all"),null);
        JsonNode result=resolve(c.request(),actor,200);
        assertEquals("UNKNOWN",result.path("status").asText());
        assertTrue(result.path("reportId").isNull()); assertTrue(result.path("detail").isNull());
        assertEquals(before,facts(c.id()));
    }

    @Test void originalActorMustStillHaveCurrentViewAndTheCurrentObjectScope() throws Exception {
        var c=create(); var before=facts(c.id());
        resolve(c.request(),auth(c.world().superAdminUserId(),c.world().employeeId(),Set.of(),null),403);
        assertEquals(before,facts(c.id()));
        FullChainEndToEndTest fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
        UUID other=fixture.createUserWithPerms(c.world(),"create-receipt-owner-"+UUID.randomUUID(),"production_daily_report:view");
        UUID owner=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);
        db.update("UPDATE production_daily_reports SET maker_id=?,row_version=row_version+1 WHERE id=?",owner,c.id());
        var withdrawn=facts(c.id());
        resolve(c.request(),reader(c),404);
        assertEquals(withdrawn,facts(c.id()));
    }

    @Test void pureCanonicalRequestSurvivesMissingCurrentMastersAndTheExactReadOnlySimulationRoute() throws Exception {
        var c=create(); var before=facts(c.id());
        // Required billDate is explicit in the original body; omitted defaults
        // remain omitted. The resolver must not resolve today's master data.
        assertNotNull(c.request().getBillDate()); assertNull(c.request().getItems().getFirst().getDefectQty());
        UUID product=c.request().getItems().getFirst().getGoodsId();
        db.update("UPDATE goods SET is_deleted=TRUE WHERE id=?",product);
        c.request().getItems().getFirst().setDefectQty(BigDecimal.ZERO); // canonical absent=zero contract
        var simulated=auth(c.world().superAdminUserId(),c.world().employeeId(),
                Set.of("production_daily_report:view"),UUID.randomUUID());
        assertEquals("COMMITTED",resolve(c.request(),simulated,200).path("status").asText());
        assertEquals(before,facts(c.id()));
        var write=http.perform(post("/api/production/daily-reports").with(authentication(simulated))
                .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsBytes(c.request())))
                .andReturn().getResponse();
        assertEquals(403,write.getStatus());
        assertEquals("IMPERSONATION_READ_ONLY",json.readTree(write.getContentAsByteArray()).path("code").asText());
        assertEquals(before,facts(c.id()));
        c.request().setIdempotencyKey("unseen-create-"+UUID.randomUUID());
        JsonNode absent=resolve(c.request(),reader(c),200);
        assertEquals("UNKNOWN",absent.path("status").asText());
        assertTrue(absent.path("detail").isNull()); assertEquals(before,facts(c.id()));
        c.request().setBillDate(null);
        resolve(c.request(),reader(c),422); // no implicit today fallback in read resolution
    }

    @Test void originalPlatformCellsAreFrozenBeforeSaveAndOnlyTheirSetOrderCanChange() throws Exception {
        var c=request();
        var first=fields.create("production_daily_report_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition(
                "原始编号-"+UUID.randomUUID(),"TEXT",false,null));
        var second=fields.create("production_daily_report_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition(
                "现场备注-"+UUID.randomUUID(),"TEXT",false,null));
        var cells=List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(first.id(),"001"),
                new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(second.id(),"原备注"));
        c.request().getItems().getFirst().setPlatformFields(
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,cells));
        byte[] original=json.writeValueAsBytes(c.request()); // exact bytes before any save mutation
        var saved=reports.create(c.request());
        c=new Case(c.world(),json.readValue(original,DailyReportSaveRequest.class),saved.getId(),original);
        JsonNode result=resolveBody(original,reader(c),200);assertEquals("COMMITTED",result.path("status").asText());
        String originalProof=result.path("fullPayloadHash").asText();var before=facts(c.id());
        c.request().getItems().getFirst().setPlatformFields(
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,List.of(cells.getLast(),cells.getFirst())));
        assertEquals(originalProof,resolve(c.request(),reader(c),200).path("fullPayloadHash").asText());
        c.request().getItems().getFirst().setPlatformFields(
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,
                        List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(first.id(),"1"),cells.getLast())));
        resolve(c.request(),reader(c),409);assertEquals(before,facts(c.id()));
        // A later edit is not the original submitted body; original read recovery
        // must still work without recomputing the proof from today's values.
        login(c.world().superAdminUserId());
        UUID item=saved.getItems().getFirst().getId();
        long version=db.queryForObject("SELECT version FROM platform_record_fields WHERE scope='production_daily_report_item' AND record_id=?",Long.class,item);
        fields.write("production_daily_report_item",item,new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(version,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(first.id(),"999"),cells.getLast())));
        assertEquals(originalProof,resolveBody(original,reader(c),200).path("fullPayloadHash").asText());
        assertEquals(originalProof,db.queryForObject("SELECT create_payload_hash FROM production_daily_report_commands WHERE report_id=?",String.class,c.id()));
    }

    @Test void failureAtCommandInsertRollsBackTheReportAndBothProofsAndExactOriginalBytesCanThenSucceed() throws Exception {
        var c=request();String key="CREATE-PROOF-ROLLBACK-"+UUID.randomUUID();
        c.request().setIdempotencyKey(key);c.request().setRemark(key);byte[] original=json.writeValueAsBytes(c.request());
        db.execute("""
                CREATE FUNCTION closeout_reject_create_proof() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                  IF NEW.idempotency_key LIKE 'CREATE-PROOF-ROLLBACK-%' THEN
                    IF NEW.create_payload_version IS DISTINCT FROM 1 OR NEW.create_payload_hash IS NULL THEN
                      RAISE EXCEPTION 'full proof must already be frozen at the command insert';
                    END IF;
                    RAISE EXCEPTION 'synthetic command-insert failure after report persistence';
                  END IF;
                  RETURN NEW;
                END; $$;
                CREATE TRIGGER closeout_reject_create_proof BEFORE INSERT ON production_daily_report_commands
                FOR EACH ROW EXECUTE FUNCTION closeout_reject_create_proof();
                """);
        try { assertThrows(RuntimeException.class,()->reports.create(c.request())); }
        finally { db.execute("DROP TRIGGER closeout_reject_create_proof ON production_daily_report_commands; DROP FUNCTION closeout_reject_create_proof()"); }
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_reports WHERE remark=?",Integer.class,key));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE idempotency_key=?",Integer.class,key));
        login(c.world().superAdminUserId());
        DailyReportSaveRequest retry=json.readValue(original,DailyReportSaveRequest.class);
        UUID id=reports.create(retry).getId();var committed=new Case(c.world(),json.readValue(original,DailyReportSaveRequest.class),id,original);
        assertEquals("COMMITTED",resolveBody(original,reader(committed),200).path("status").asText());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_daily_reports WHERE remark=?",Integer.class,key));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE idempotency_key=? AND create_payload_version=1 AND create_payload_hash IS NOT NULL",Integer.class,key));
    }

    @Test void historicalNullProofIsNeverClaimedAsCompleteAndAcceptedNativeV3PostReplayIsUnchanged() throws Exception {
        var c=request();UUID id=UUID.randomUUID();
        String hash=ReflectionTestUtils.invokeMethod(ProductionDailyReportService.class,"createRequestHash",c.request());
        // Synthetic historical read projection: no complete-body proof exists.
        // Its native receipt is not presented as proof of quantities or fields.
        db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,maker_id) VALUES(?,?,?,?)",
                id,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_DAILY_REPORT),c.request().getBillDate(),c.world().employeeId());
        db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind) VALUES(?,?,?,?,?,'CREATE')",
                c.world().superAdminUserId(),c.request().getIdempotencyKey(),hash,id,c.world().superAdminUserId());
        c=new Case(c.world(),c.request(),id,c.originalBody());var before=facts(id);
        JsonNode old=resolveBody(c.originalBody(),reader(c),200);
        assertEquals("LEGACY_UNCONFIRMED",old.path("status").asText());
        assertEquals(id.toString(),old.path("reportId").asText());
        assertTrue(old.path("fullPayloadHash").isNull());assertTrue(old.path("fullPayloadVersion").isNull());
        assertTrue(old.path("detail").path("historyReadOnly").asBoolean());
        assertEquals(before,facts(id));
        c.request().getItems().getFirst().setPlatformFields(
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,-1,List.of()));
        assertEquals("LEGACY_UNCONFIRMED",resolve(c.request(),reader(c),200).path("status").asText(),
                "Absent historical proof cannot invent a new extension-body validation contract");
        for(String sql:List.of(
                "UPDATE production_daily_report_commands SET create_payload_version=1,create_payload_hash=repeat('a',64) WHERE report_id='"+id+"'",
                "DELETE FROM production_daily_report_commands WHERE report_id='"+id+"'",
                "TRUNCATE production_daily_report_commands")) {
            var rejected=assertThrows(org.springframework.dao.DataAccessException.class,()->db.execute(sql));
            assertInstanceOf(org.postgresql.util.PSQLException.class,rejected.getMostSpecificCause());
            assertEquals("55000",((org.postgresql.util.PSQLException)rejected.getMostSpecificCause()).getSQLState());
        }
        assertEquals(before,facts(id));
        login(c.world().superAdminUserId());
        assertEquals(id,reports.create(json.readValue(c.originalBody(),DailyReportSaveRequest.class)).getId());
        assertEquals(before,facts(id));
        assertNull(db.queryForObject("SELECT create_payload_hash FROM production_daily_report_commands WHERE report_id=?",String.class,id));
    }

    private Case create() throws Exception {
        var c=request();UUID id=reports.create(c.request()).getId();
        // Never reuse a request instance mutated by save/lineage/defaults.
        return new Case(c.world(),json.readValue(c.originalBody(),DailyReportSaveRequest.class),id,c.originalBody());
    }
    private Case request() throws Exception {
        var workshop=new WorkshopPublicSurplusEndToEndTest(); beans.autowireBean(workshop); workshop.prepare();
        Object task=ReflectionTestUtils.invokeMethod(workshop,"createStartedTask","create-receipt-"+UUID.randomUUID(),false,"10");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");
        @SuppressWarnings("unchecked") List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(workshop,"sources",task);
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(workshop,"reportRequest",task,sources.getFirst(),"4","4");
        return new Case(world,request,null,json.writeValueAsBytes(request));
    }
    private JsonNode resolve(DailyReportSaveRequest request,Authentication actor,int expected) throws Exception {
        return resolveBody(json.writeValueAsBytes(request),actor,expected);
    }
    private JsonNode resolveBody(byte[] originalBody,Authentication actor,int expected) throws Exception {
        var result=http.perform(post(PATH).with(authentication(actor)).contentType(MediaType.APPLICATION_JSON)
                .content(originalBody)).andReturn();
        assertEquals(expected,result.getResponse().getStatus(),result.getResponse().getContentAsString());
        return json.readTree(result.getResponse().getContentAsByteArray());
    }
    private Authentication reader(Case c) { return auth(c.world().superAdminUserId(),c.world().employeeId(),Set.of("production_daily_report:view"),null); }
    private Authentication auth(UUID user,UUID employee,Set<String> permissions,UUID impersonator) {
        var principal=new AuthUser(user,employee,"create-receipt-reader",permissions,false,true,false,false,impersonator);
        return new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities());
    }
    private void login(UUID user) { var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);fixture.loginAs(user); }
    private Map<String,Object> facts(UUID id) {
        return db.queryForMap("""
                SELECT report.status,report.row_version,report.is_deleted,report.xmin::text AS report_xmin,
                       (SELECT count(*) FROM production_daily_report_commands WHERE report_id=report.id) AS commands,
                       (SELECT count(*) FROM production_daily_report_items WHERE report_id=report.id) AS items,
                       (SELECT count(*) FROM stock_movements) AS movements
                FROM production_daily_reports report WHERE report.id=?
                """,id);
    }
    private record Case(FullChainEndToEndTest.World world,DailyReportSaveRequest request,UUID id,byte[] originalBody) {}
}
