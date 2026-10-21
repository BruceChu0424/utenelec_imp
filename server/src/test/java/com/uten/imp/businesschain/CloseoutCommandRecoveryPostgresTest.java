package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real planning, request quantities and FQC facts; only actor permissions are controlled at the HTTP boundary. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.concurrency.verify-nested-footprint=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class CloseoutCommandRecoveryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired StockDocService stock;
    @Autowired ProductionDrawRequestService requests;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired PlatformTransactionManager manager;
    @AfterEach void clean(){SecurityContextHolder.clearContext();ProductionJdbcMeasurement.end();}
    record Setup(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,List<UUID> documents){}

    @Test void reviewedCommitReplaysOriginalTokenAndReadOnlyRecoveryNeedsNoIssueOrApprovalPermission()throws Exception {
        Setup setup=draws(3,true);var request=reviewed(setup.documents());Authentication writer=actor();
        JsonNode first=write("/api/stock/docs/issue-batch",writer,request,200);assertEquals(3,first.path("issuedCount").asInt());
        long movements=movements(setup.documents());
        SecurityContextHolder.getContext().setAuthentication(writer);
        var changed=stock.issueBatchReview(setup.documents());
        assertNotEquals(request.getReviews().getFirst().reviewToken(),changed.documents().getFirst().reviewToken());
        JsonNode replay=write("/api/stock/docs/issue-batch",writer,request,200);
        assertTrue(replay.path("replayed").asBoolean());assertEquals(3,replay.path("replayedCount").asInt());
        assertEquals(movements,movements(setup.documents()));
        Authentication reader=principal(setup.world().superAdminUserId(),setup.world().employeeId(),Set.of("stock_doc:view","stock_doc:view:all"));
        JsonNode receipt=read("/api/stock/docs/issue-batch/receipt",reader,request.getIdempotencyKey(),200);
        assertEquals("COMMITTED",receipt.path("state").asText());assertEquals(first,receipt.path("result"));
        write("/api/stock/docs/issue-batch",reader,request,403);
        assertEquals(movements,movements(setup.documents()));
    }
    @Test void newRequestedQuantityInvalidatesSeenReviewBeforeApprovalAndLeavesTheKeyReusable()throws Exception {
        Setup setup=draws(1,false);submitRemaining(setup.documents().getFirst(),true);
        var request=reviewed(setup.documents());Authentication writer=actor();
        var oldQuantities=stock.issueBatchReview(setup.documents()).documents().getFirst().items();
        submitRemaining(setup.documents().getFirst(),false);
        assertNotEquals(oldQuantities,stock.issueBatchReview(setup.documents()).documents().getFirst().items());
        write("/api/stock/docs/issue-batch",writer,request,409);
        assertEquals(0,movements(setup.documents()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE idempotency_key=?",Integer.class,request.getIdempotencyKey()));
        assertEquals(0,db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,setup.documents().getFirst()));
        SecurityContextHolder.getContext().setAuthentication(writer);
        request.setReviews(stock.issueBatchReview(setup.documents()).documents().stream()
                .map(row->new StockDocIssueBatchRequest.DocumentReview(row.docId(),row.reviewToken())).toList());
        assertEquals(1,write("/api/stock/docs/issue-batch",writer,request,200).path("issuedCount").asInt());
    }
    @Test void anUncommittedBatchNeverBecomesACommittedReceiptInTheSameJvm() {
        Setup setup=draws(1,true);var request=reviewed(setup.documents());
        new TransactionTemplate(manager).executeWithoutResult(status->{
            stock.issueFullBatch(request);
            assertEquals("UNKNOWN",stock.issueBatchReceipt(request.getIdempotencyKey()).state());
        });
        assertEquals("COMMITTED",stock.issueBatchReceipt(request.getIdempotencyKey()).state());
    }
    @Test void originalActorReadRequiresCurrentObjectVisibilityAndDifferentActorCannotClaimTheKey()throws Exception {
        Setup setup=draws(1,true);UUID user=setup.fixture().createUserWithPerms(setup.world(),"receipt-reader-"+UUID.randomUUID(),
                "stock_doc:view","stock_doc:approve","stock_doc:issue");
        UUID warehouseDepartment=db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted",UUID.class);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",warehouseDepartment,user);
        setup.fixture().loginAs(user);var request=reviewed(setup.documents());Authentication writer=actor();
        write("/api/stock/docs/issue-batch",writer,request,200);
        Authentication foreign=principal(setup.world().superAdminUserId(),setup.world().employeeId(),Set.of("stock_doc:view","stock_doc:view:all"));
        assertEquals("UNKNOWN",read("/api/stock/docs/issue-batch/receipt",foreign,request.getIdempotencyKey(),200).path("state").asText());
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);
        Authentication viewOnly=principal(user,employee,Set.of("stock_doc:view"));
        assertEquals("COMMITTED",read("/api/stock/docs/issue-batch/receipt",viewOnly,request.getIdempotencyKey(),200).path("state").asText());
        UUID otherDepartment=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,setup.world().employeeId());
        db.update("UPDATE employees SET department_id=? WHERE id=?",otherDepartment,employee);
        read("/api/stock/docs/issue-batch/receipt",viewOnly,request.getIdempotencyKey(),404);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE actor_user_id=? AND idempotency_key=?",Integer.class,user,request.getIdempotencyKey()));
    }
    @Test void oneAndFiftyDocumentReviewsUseConstantStatementCountAndFiftyOneRawIdsAreRejected()throws Exception {
        Setup setup=draws(50,true);long one,many;
        var first=ProductionJdbcMeasurement.begin();try{assertEquals(1,stock.issueBatchReview(List.of(setup.documents().getFirst())).documents().size());}finally{ProductionJdbcMeasurement.end();}one=first.logicalStatements;
        var batch=ProductionJdbcMeasurement.begin();try{assertEquals(50,stock.issueBatchReview(setup.documents()).documents().size());}finally{ProductionJdbcMeasurement.end();}many=batch.logicalStatements;
        assertEquals(one,many,"authorization and current row facts must be batched, not repeated fifty times");
        assertTrue(many<=4,"view review must use a bounded constant number of SQL statements");
        assertThrows(com.uten.imp.common.web.ApiException.class,()->stock.issueBatchReview(java.util.Collections.nCopies(51,setup.documents().getFirst())));
        System.out.println("CLOSEOUT-DRAW-REVIEW one="+one+" fifty="+many);
    }
    @Test void fqcReceiptUsesOriginalActorAndReadScopeAndDifferentActorCannotReplayItsDecision()throws Exception {
        Object source=fqc(1,"plain");List<UUID> inspections=ReflectionTestUtils.invokeMethod(source,"inspections");
        var world=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(source,"world");
        UUID inspection=inspections.getFirst();UUID qa=qualityActor(world),other=qualityActor(world);
        UUID qaEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,qa);
        Authentication writer=principal(qa,qaEmployee,Set.of("production_quality_inspection:view","production_quality_inspection:approve"));
        String key="closeout-fqc-"+UUID.randomUUID();var request=new DecisionRequest("PASS",new BigDecimal("0.5"),null,null,null,key);
        JsonNode first=write("/api/production/quality-inspections/"+inspection+"/decisions",writer,request,200);
        UUID otherEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);
        Authentication otherWriter=principal(other,otherEmployee,Set.of("production_quality_inspection:view","production_quality_inspection:approve"));
        write("/api/production/quality-inspections/"+inspection+"/decisions",otherWriter,request,409);
        assertEquals("UNKNOWN",read("/api/production/quality-inspections/"+inspection+"/decision-receipt",otherWriter,key,200).path("state").asText());
        Authentication reader=principal(qa,qaEmployee,Set.of("production_quality_inspection:view"));
        // View-only recovery is independent of approval, but still requires today's report-owner read scope.
        UUID reportMaker=fqcReportMaker(inspection);
        read("/api/production/quality-inspections/"+inspection+"/decision-receipt",reader,key,404);
        allowFqcReceiptRead(qa,reportMaker);
        JsonNode receipt=read("/api/production/quality-inspections/"+inspection+"/decision-receipt",reader,key,200);
        assertEquals("COMMITTED",receipt.path("state").asText());assertEquals(first.path("decisionEventId"),receipt.path("result").path("decisionEventId"));
        assertEquals(0,receipt.path("decision").path("passQty").decimalValue().compareTo(new BigDecimal("0.5")));
        allowFqcReceiptRead(other,reportMaker);
        Authentication otherReader=principal(other,otherEmployee,Set.of("production_quality_inspection:view"));
        assertEquals("UNKNOWN",read("/api/production/quality-inspections/"+inspection+"/decision-receipt",otherReader,key,200).path("state").asText());
        write("/api/production/quality-inspections/"+inspection+"/decisions",reader,request,403);
        removeFqcReceiptRead(qa,reportMaker);
        read("/api/production/quality-inspections/"+inspection+"/decision-receipt",reader,key,404);
        read("/api/production/quality-inspections/"+inspection+"/decision-receipt",principal(qa,qaEmployee,Set.of()),key,403);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_fqc_decision_events WHERE inspection_id=?",Integer.class,inspection));
    }
    @Test void passAllHasItsOwnReadOnlyReceiptAndWholeBatchVisibility()throws Exception {
        // Separate real reports make the all-or-nothing read check cover two distinct responsible employees.
        Object source=fqc(1,"mixed"),secondSource=fqc(1,"plain");
        List<UUID> inspections=new ArrayList<>(ReflectionTestUtils.<List<UUID>>invokeMethod(source,"inspections"));
        inspections.addAll(ReflectionTestUtils.<List<UUID>>invokeMethod(secondSource,"inspections"));
        UUID firstMaker=fqcReportMaker(inspections.getFirst()),secondMaker=fqcReportMaker(inspections.getLast());
        assertNotEquals(firstMaker,secondMaker);
        var world=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(source,"world");UUID qa=qualityActor(world);
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,qa);
        Authentication writer=principal(qa,employee,Set.of("production_quality_inspection:view","production_quality_inspection:approve"));
        String key="closeout-pass-all-"+UUID.randomUUID();JsonNode result=write("/api/production/quality-inspections/decisions/pass-all",writer,new PassAllBatchRequest(inspections,key),200);
        Authentication reader=principal(qa,employee,Set.of("production_quality_inspection:view"));
        read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,key,404);
        allowFqcReceiptRead(qa,firstMaker);
        read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,key,404);
        allowFqcReceiptRead(qa,secondMaker);
        JsonNode receipt=read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,key,200);
        assertEquals("COMMITTED",receipt.path("state").asText());assertEquals(result.path("batchId"),receipt.path("result").path("batchId"));
        assertEquals(2,receipt.path("result").path("items").size());
        assertEquals("UNKNOWN",read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,"absent-pass-all-key",200).path("state").asText());
        removeFqcReceiptRead(qa,firstMaker);
        read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,key,404);
        allowFqcReceiptRead(qa,firstMaker);
        assertEquals("COMMITTED",read("/api/production/quality-inspections/decisions/pass-all/receipt",reader,key,200).path("state").asText());
        write("/api/production/quality-inspections/decisions/pass-all",reader,new PassAllBatchRequest(inspections,key),403);
        UUID other=qualityActor(world),otherEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);
        assertEquals("UNKNOWN",read("/api/production/quality-inspections/decisions/pass-all/receipt",
                principal(other,otherEmployee,Set.of("production_quality_inspection:view")),key,200).path("state").asText());
        assertEquals(2,inspections.stream().mapToInt(id->db.queryForObject("SELECT count(*) FROM production_fqc_decision_events WHERE inspection_id=?",Integer.class,id)).sum());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batches WHERE created_by=? AND idempotency_key=?",Integer.class,qa,key));
    }
    @Test void discoveryReceiptCannotResolveAnOrdinaryKeyOrCreateAConfiguration()throws Exception {
        Setup setup=draws(1,true);var request=reviewed(setup.documents());Authentication writer=actor();
        write("/api/stock/docs/issue-batch",writer,request,200);
        assertEquals("UNKNOWN",read("/api/stock/docs/issue-discovery-batch/receipt",writer,request.getIdempotencyKey(),200).path("state").asText());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",Integer.class,request.getIdempotencyKey()));
    }

    private Setup draws(int count,boolean full){var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("closeout-cmd-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        for(UUID goods:List.of(world.goodsB(),world.goodsE())){ db.update("INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty) VALUES(?,?,NULL,100000)",world.warehouseId(),goods); }
        List<UUID> ids=new ArrayList<>();for(int i=0;i<count;i++){ ids.add(ReflectionTestUtils.invokeMethod(fixture,"generateSingleWarehouseDraw",world,"closeout-draw-"+UUID.randomUUID())); }
        ids.sort(java.util.Comparator.comparing(UUID::toString));if(full){ fixture.requestWorkshopDraws("closeout-request-"+UUID.randomUUID(),ids); }return new Setup(fixture,world,List.copyOf(ids));}
    private StockDocIssueBatchRequest reviewed(List<UUID> ids){var request=new StockDocIssueBatchRequest();request.setIdempotencyKey("closeout-issue-"+UUID.randomUUID());request.setDocIds(ids);request.setProtocolVersion(2);
        request.setReviews(stock.issueBatchReview(ids).documents().stream().map(row->new StockDocIssueBatchRequest.DocumentReview(row.docId(),row.reviewToken())).toList());return request;}
    private void submitRemaining(UUID document,boolean half){UUID segment=db.queryForObject("SELECT execution_segment_id FROM production_planning_package_documents WHERE document_id=? AND document_type='DRAW'",UUID.class,document);
        Long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);var ids=List.of(new ProductionDrawRequest.Item(segment,version));
        var preview=requests.preview(new ProductionDrawRequest.PreviewRequest(ids));requests.submit(new ProductionDrawRequest.SubmitRequest(ids,"closeout-request-"+UUID.randomUUID(),preview.fingerprint(),
                preview.lines().stream().map(line->new ProductionDrawRequest.Selection(line.drawItemId(),half?line.qty().divide(BigDecimal.valueOf(2)):line.qty())).toList()));}
    private Object fqc(int size,String mode){var fixture=new ProductionFqcPreStockBatchEndToEndTest();ReflectionTestUtils.setField(fixture,"beans",beans);ReflectionTestUtils.setField(fixture,"db",db);
        ReflectionTestUtils.setField(fixture,"analyses",analyses);ReflectionTestUtils.setField(fixture,"commands",commands);ReflectionTestUtils.setField(fixture,"stock",stock);ReflectionTestUtils.setField(fixture,"arrivals",arrivals);
        return ReflectionTestUtils.invokeMethod(fixture,"prepare",size,mode);}
    private UUID qualityActor(FullChainEndToEndTest.World world){var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);UUID user=fixture.createUserWithPerms(world,"closeout-qa-"+UUID.randomUUID(),"production_quality_inspection:view","production_quality_inspection:approve");
        UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_QA' AND NOT is_deleted",UUID.class);db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",department,user);return user;}
    private UUID fqcReportMaker(UUID inspection){return db.queryForObject("SELECT report_maker_id FROM production_fqc_inspections WHERE id=?",UUID.class,inspection);}
    private void allowFqcReceiptRead(UUID reader,UUID reportMaker){assertEquals(1,db.update("""
            INSERT INTO user_data_scopes(user_id,scope,owner_employee_id,owner_employment_generation)
            SELECT ?,'production_plan',employee.id,
                   (SELECT count(*) FROM employment_history history
                    WHERE history.employee_id=employee.id AND history.event_type='rehire')
            FROM employees employee
            WHERE employee.id=? AND NOT employee.is_deleted AND employee.status IN ('active','probation','onLeave')
            ON CONFLICT(user_id,scope,owner_employee_id) DO UPDATE
            SET owner_employment_generation=EXCLUDED.owner_employment_generation
            """,reader,reportMaker));}
    private void removeFqcReceiptRead(UUID reader,UUID reportMaker){assertEquals(1,db.update(
            "DELETE FROM user_data_scopes WHERE user_id=? AND scope='production_plan' AND owner_employee_id=?",reader,reportMaker));}
    private Authentication actor(){return SecurityContextHolder.getContext().getAuthentication();}
    private Authentication principal(UUID user,UUID employee,Set<String> permissions){return new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(new AuthUser(user,employee,"closeout-test",permissions,false,true,false),null,new AuthUser(user,employee,"closeout-test",permissions,false,true,false).getAuthorities());}
    private JsonNode write(String path,Authentication actor,Object body,int status)throws Exception{var response=http.perform(post(path).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(body))).andReturn().getResponse();assertEquals(status,response.getStatus(),response.getContentAsString());return json.readTree(response.getContentAsByteArray());}
    private JsonNode read(String path,Authentication actor,String key,int status)throws Exception{var response=http.perform(get(path).with(authenticated(actor)).param("idempotencyKey",key)).andReturn().getResponse();assertEquals(status,response.getStatus(),response.getContentAsString());return json.readTree(response.getContentAsByteArray());}
    private long movements(List<UUID> docs){return new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db)
            .queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN (:docs)",java.util.Map.of("docs",docs),Long.class);}
}
