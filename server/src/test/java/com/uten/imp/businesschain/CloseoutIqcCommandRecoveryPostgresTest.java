package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.dto.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
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
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Actual commercial receipt/cost fixtures with immutable IQC actor, whole-report recovery and no new quantity on read. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class CloseoutIqcCommandRecoveryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired PlatformTransactionManager manager;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    record Source(String type,UUID receipt,List<WarehouseIqcScaleFixture.Receipt> rows,Authentication actor){}

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void originalFullReportCanBeReadWithoutHandleAndNeverRepublishedOrClaimedByAnotherActor(String type)throws Exception {
        Source source=prepare(type);BatchInspectionDecideRequest request=report(source);
        call(path(source,"decide-batch"),source.actor(),request,200);
        String facts=facts(source);UUID original=((AuthUser)source.actor().getPrincipal()).getId();
        assertEquals(6,db.queryForObject("SELECT count(*) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=? AND e.action IN('PASS','FAIL') AND e.actor_user_id=?",Integer.class,source.receipt(),original));
        AuthUser originalUser=(AuthUser)source.actor().getPrincipal();Authentication read=principal(originalUser.getId(),originalUser.getEmployeeId(),Set.of("procurement_inspection:view"));
        JsonNode result=call(path(source,"decide-batch/receipt"),read,request,200);
        assertEquals("COMMITTED",result.path("state").asText());assertEquals(6,result.path("events").size());
        assertEquals(facts,facts(source));call(path(source,"decide-batch"),read,request,403);
        UUID foreign=anotherUser(source);UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,foreign);
        Authentication other=principal(foreign,employee,Set.of("procurement_inspection:view","procurement_inspection:handle"));
        assertEquals("UNKNOWN",call(path(source,"decide-batch/receipt"),other,request,200).path("state").asText());
        call(path(source,"decide-batch"),other,request,409);assertEquals(facts,facts(source));
        var changed=new BatchInspectionDecideRequest(request.items(),"不同原报告原因");
        call(path(source,"decide-batch/receipt"),read,changed,409);assertEquals(facts,facts(source));
    }
    @Test void compatibleOwnSinglePassesRemainReadLegacyAndCannotFillAnUnfinishedNewMember()throws Exception {
        Source source=prepare("PURCHASE");var items=source.rows().stream().map(row->new BatchInspectionPassRequest.Item(row.inspectionId(),new BigDecimal("1.2500"),"closeout-pass-"+row.inspectionId())).toList();
        var pass=new BatchInspectionPassRequest(items,null);
        for(var item:items)inspections.dispose(source.type(),source.receipt(),item.inspectionItemId(),new InspectionDispositionRequest("PASS",item.expectedRemainingBaseQty(),null,item.idempotencyKey()));
        String original=facts(source);inspections.passBatch(source.type(),source.receipt(),pass);assertEquals(original,facts(source));
        assertEquals("LEGACY",call(path(source,"pass-batch/receipt"),source.actor(),pass,200).path("state").asText());
        UUID foreign=anotherUser(source);UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,foreign);
        Authentication other=principal(foreign,employee,Set.of("procurement_inspection:view","procurement_inspection:handle"));
        assertEquals("UNKNOWN",call(path(source,"pass-batch/receipt"),other,pass,200).path("state").asText());
        call(path(source,"pass-batch"),other,pass,409);assertEquals(original,facts(source));
        Source pending=prepare("SUBCONTRACT");var first=pending.rows().getFirst();String key="closeout-old-single-"+first.inspectionId();
        inspections.dispose(pending.type(),pending.receipt(),first.inspectionId(),new InspectionDispositionRequest("PASS",new BigDecimal("1.2500"),null,key));
        var mixed=new BatchInspectionPassRequest(pending.rows().stream().map(row->new BatchInspectionPassRequest.Item(row.inspectionId(),new BigDecimal("1.2500"),row==first?key:"closeout-new-member-"+row.inspectionId())).toList(),null);
        String before=facts(pending);call(path(pending,"pass-batch"),pending.actor(),mixed,409);assertEquals(before,facts(pending));
    }
    @Test void readOnlyReportCannotObserveTheCallingTransactionsUncommittedEvents() {
        Source source=prepare("PURCHASE");var request=report(source);
        new TransactionTemplate(manager).executeWithoutResult(status->{
            inspections.decideBatch(source.type(),source.receipt(),request);
            assertEquals("UNKNOWN",inspections.decideBatchReceipt(source.type(),source.receipt(),request).state());
        });
        assertEquals("COMMITTED",inspections.decideBatchReceipt(source.type(),source.receipt(),request).state());
    }
    @Test void nonCommandReceivedEventsDoNotInventQualityCommandUsersFromEmployeeSnapshots() {
        Source source=prepare("PURCHASE");
        assertTrue(db.queryForObject("SELECT count(*) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=? AND e.action='RECEIVED' AND e.actor_user_id IS NULL",Integer.class,source.receipt())>0);
        assertEquals(0,db.queryForObject("SELECT count(*) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=? AND e.action='RECEIVED' AND e.actor_user_id IS NOT NULL",Integer.class,source.receipt()));
    }
    @Test void aForeignReceiptNamespaceCannotReadOrConfirmSelectedEvents()throws Exception {
        Source source=prepare("PURCHASE");var request=report(source);call(path(source,"decide-batch"),source.actor(),request,200);
        String facts=facts(source);call("/api/procurement/inspection/PURCHASE/"+UUID.randomUUID()+"/decide-batch/receipt",source.actor(),request,404);
        assertEquals(facts,facts(source));
    }

    private Source prepare(String type){var fixture=new WarehouseIqcMultiLineFixture(beans,db).prepare(2,3,"closeout-iqc-"+UUID.randomUUID().toString().substring(0,8));
        var masters=new FullChainEndToEndTest();beans.autowireBean(masters);masters.loginAs(fixture.world().superAdminUserId());
        var rows=fixture.receipts().stream().filter(receipt->receipt.type().equals(type)).toList();return new Source(type,rows.getFirst().id(),rows,SecurityContextHolder.getContext().getAuthentication());}
    private BatchInspectionDecideRequest report(Source source){return new BatchInspectionDecideRequest(source.rows().stream().map(row->new BatchInspectionDecideRequest.Item(row.inspectionId(),new BigDecimal("1.2500"),new BigDecimal("0.75"),new BigDecimal("0.50"),"closeout-iqc-key-"+row.inspectionId())).toList(),"真实原检验报告");}
    private String path(Source source,String action){return "/api/procurement/inspection/"+source.type()+"/"+source.receipt()+"/"+action;}
    private UUID anotherUser(Source source){var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("closeout-foreign-"+UUID.randomUUID());return fixture.createUserWithPerms(world,"iqc-other-"+UUID.randomUUID(),"procurement_inspection:view","procurement_inspection:handle");}
    private Authentication principal(UUID id,UUID employee,Set<String> permissions){var user=new AuthUser(id,employee,"iqc-read-test",permissions,false,true,false);return new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities());}
    private JsonNode call(String path,Authentication actor,Object body,int expected)throws Exception{var response=http.perform(post(path).with(authentication(actor)).contentType("application/json").content(json.writeValueAsBytes(body))).andReturn().getResponse();assertEquals(expected,response.getStatus(),response.getContentAsString());SecurityContextHolder.getContext().setAuthentication(actor);return response.getContentAsByteArray().length==0?json.createObjectNode():json.readTree(response.getContentAsByteArray());}
    private String facts(Source source){return db.queryForObject("""
            SELECT jsonb_build_object('inspections',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM procurement_inspection_items i WHERE receipt_id=?),
                'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=?),
                'payable',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM ar_ap_ledger a WHERE source_doc_id=?))::text
            """,String.class,source.receipt(),source.receipt(),source.receipt());}
}
