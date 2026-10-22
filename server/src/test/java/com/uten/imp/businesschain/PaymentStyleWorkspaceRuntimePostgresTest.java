package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.paymentstyle.PaymentStyleInlineEditService;
import com.uten.imp.features.master.paymentstyle.PaymentStyleService;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only"})
@AutoConfigureMockMvc(addFilters=false)
class PaymentStyleWorkspaceRuntimePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired PaymentStyleInlineEditService inline;
    @Autowired PaymentStyleService styles;
    @Autowired com.uten.imp.features.master.history.MasterRecordHistoryService sharedHistory;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc mvc;
    UUID actor,employee;

    @BeforeEach void setup() {
        actor=db.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        login(Set.of("payment_style:view","payment_style:create","payment_style:edit","payment_style:status","payment_style:reorder","payment_style:move"));
    }
    @AfterEach void clear() {RequestContextHolder.resetRequestAttributes();SecurityContextHolder.clearContext();}

    @Test void literalHttpRouteUsesTheDedicatedCasWriterAndCapturesBothHistories() throws Exception {
        UUID id=create("http original",null,"EXPENSE");String code=text("code",id);
        db.update("UPDATE payment_styles SET init_balance=123.4500,is_receipt=true WHERE id=?",id);
        long personal=history("master_operation_history"),shared=versions(id);
        var response=mvc.perform(patch("/api/master/inline-edit/payment-styles/{id}",id).contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(Map.of("expected",Map.of("name","http original"),"changes",Map.of("name","http changed")))))
            .andExpect(status().isOk()).andReturn();
        assertTrue(response.getResponse().getContentAsString().contains("http changed"));
        assertEquals("http changed",text("name",id));assertEquals(code,text("code",id));
        assertEquals(0,new BigDecimal("123.4500").compareTo(db.queryForObject("SELECT init_balance FROM payment_styles WHERE id=?",BigDecimal.class,id)));
        assertTrue(db.queryForObject("SELECT is_receipt FROM payment_styles WHERE id=?",Boolean.class,id));
        assertEquals(personal+1,history("master_operation_history"));assertEquals(shared+1,versions(id));
    }
    @Test void staleFieldValuesNeverOverwriteAConcurrentNativeChange() {
        UUID id=create("original",null,"EXPENSE");db.update("UPDATE payment_styles SET name='concurrent' WHERE id=?",id);
        long before=versions(id);route("/api/master/inline-edit/payment-styles/"+id,"PATCH");
        ApiException denied=assertThrows(ApiException.class,()->inline.patch(id,Map.of("name","original"),Map.of("name","stale")));
        assertEquals(ErrorCode.CONFLICT,denied.getCode());assertEquals("concurrent",text("name",id));assertEquals(before,versions(id));
    }
    @Test void editedBusinessFlagsProduceDistinctAccurateChineseHistoryLabels() {
        UUID id=create("business flags",null,"EXPENSE");route("/api/master/inline-edit/payment-styles/"+id,"PATCH");
        inline.patch(id,Map.of("departmental",false,"receipt",false,"payment",false),Map.of("departmental",true,"receipt",true,"payment",true));
        var revision=sharedHistory.list("payment-styles",id,null,null).entries().getFirst();
        var detail=sharedHistory.detail("payment-styles",historyId(revision.id()));
        assertTrue(detail.changes().stream().anyMatch(change->change.field().equals("is_departmental")&&change.label().equals("部门核算")));
        assertTrue(detail.changes().stream().anyMatch(change->change.field().equals("is_receipt")&&change.label().equals("收款标志")));
        assertTrue(detail.changes().stream().anyMatch(change->change.field().equals("is_payment")&&change.label().equals("付款标志")));
        assertTrue(detail.changes().stream().noneMatch(change->change.label().equals("其他资料字段")));
    }
    @Test void eachColumnRequiresItsOwnGrantAndFinancialIdentityCannotBePatched() {
        UUID id=create("permission original",null,"EXPENSE");login(Set.of("payment_style:view","payment_style:reorder"));
        route("/api/master/inline-edit/payment-styles/"+id,"PATCH");
        inline.patch(id,Map.of("sortOrder",0),Map.of("sortOrder",4));assertEquals("4",text("sort_order",id));
        assertThrows(RuntimeException.class,()->inline.patch(id,Map.of("name","permission original"),Map.of("name","forbidden")));
        assertThrows(ApiException.class,()->inline.patch(id,Map.of("code",text("code",id)),Map.of("code","NEW")));
        assertThrows(ApiException.class,()->inline.patch(id,Map.of("initBalance",0),Map.of("initBalance",900)));
        assertThrows(ApiException.class,()->inline.patch(id,Map.of("parentId",id.toString()),Map.of("parentId",UUID.randomUUID().toString())));
        assertEquals("permission original",text("name",id));
    }
    @Test void viewOnlyAccountsCannotInvokeTheActualInlineHttpEndpoint() throws Exception {
        UUID id=create("read only",null,"EXPENSE");login(Set.of("payment_style:view"));
        mvc.perform(patch("/api/master/inline-edit/payment-styles/{id}",id).contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(Map.of("expected",Map.of("name","read only"),"changes",Map.of("name","no")))))
            .andExpect(status().isForbidden());assertEquals("read only",text("name",id));
    }
    @Test void batchDisablesLeavesFirstAndEnablesAncestorsFirstInOneCapturedCommand() {
        UUID parent=create("batch parent",null,"EXPENSE"),child=create("batch child",parent,"EXPENSE");
        route("/api/master/payment-styles/batch-status","POST");long before=history("master_operation_history");
        var disabled=styles.batchStatus("禁用",List.of(new MasterBatchRequests.Item(parent,null),new MasterBatchRequests.Item(child,null)));
        assertEquals(2,disabled.succeeded());assertEquals(0,disabled.failed());assertEquals("禁用",text("status",parent));assertEquals("禁用",text("status",child));
        assertEquals(before+1,history("master_operation_history"));
        var enabled=styles.batchStatus("使用",List.of(new MasterBatchRequests.Item(child,null),new MasterBatchRequests.Item(parent,null)));
        assertEquals(2,enabled.succeeded());assertEquals("使用",text("status",parent));assertEquals("使用",text("status",child));
    }
    @Test void aReferencedLeafAndProtectedSystemSubjectAreReportedWithoutDiscardingOtherSuccesses() {
        UUID protectedId=UUID.randomUUID();
        db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,'手续费','EXPENSE','使用')",protectedId,"SYS-TEST-"+protectedId);
        UUID accountStyle=create("referenced account subject",null,"ACCOUNT"),ordinary=create("independent expense",null,"EXPENSE"),account=UUID.randomUUID();
        UUID currency=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'workspace account currency',1,'使用')",currency,"CUR-"+currency);
        db.update("INSERT INTO accounts(id,code,name,style_id,currency_id,status) VALUES(?,?,'linked active account',?,?,'使用')",account,"A-"+account,accountStyle,currency);
        route("/api/master/payment-styles/batch-status","POST");
        var result=styles.batchStatus("禁用",List.of(new MasterBatchRequests.Item(ordinary,null),new MasterBatchRequests.Item(protectedId,null),new MasterBatchRequests.Item(accountStyle,null)));
        assertEquals(1,result.succeeded());assertEquals(2,result.failed());assertEquals("禁用",text("status",ordinary));
        assertEquals("使用",text("status",protectedId));assertEquals("使用",text("status",accountStyle));
        assertTrue(result.results().stream().filter(row->!row.ok()).allMatch(row->row.reason()!=null&&!row.reason().isBlank()));
    }
    @Test void financialDeletionRemainsForbiddenAndAnUnselectedActiveChildStillBlocksItsParent() {
        UUID parent=create("protected parent",null,"EXPENSE");create("unselected active child",parent,"EXPENSE");
        assertThrows(ApiException.class,()->styles.delete(parent));route("/api/master/payment-styles/batch-status","POST");
        var refused=styles.batchStatus("禁用",List.of(new MasterBatchRequests.Item(parent,null)));
        assertEquals(0,refused.succeeded());assertEquals(1,refused.failed());assertEquals("使用",text("status",parent));
    }
    @Test void sharedCreateHistoryCannotBypassPermanentFinancialDeletionEvenForAnAdministrator() {
        UUID id=create("never delete by history",null,"EXPENSE");
        var principal=new AuthUser(actor,employee,"payment-admin",Set.of("payment_style:view","payment_style:edit"),false,true,true,false,null,UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"",principal.getAuthorities()));
        var creation=sharedHistory.list("payment-styles",id,null,null).entries().stream().filter(entry->entry.action().equals("CREATE")).findFirst().orElseThrow();
        var selected=sharedHistory.detail("payment-styles",historyId(creation.id()));
        assertFalse(selected.canRestoreBefore());assertTrue(selected.blockedReason().contains("财务类别"),selected.blockedReason());
        assertThrows(ApiException.class,()->sharedHistory.restore("payment-styles",historyId(selected.id()),selected.expectedHead(),true));
        assertFalse(db.queryForObject("SELECT is_deleted FROM payment_styles WHERE id=?",Boolean.class,id));
    }

    private UUID create(String name,UUID parent,String category) {
        var request=new PaymentStyleSaveRequest();request.setName(name+" "+UUID.randomUUID());request.setCategory(category);request.setParentId(parent);request.setStatus("使用");
        UUID id=styles.create(request).getId();
        // Keep assertions readable while the generated code remains authoritative.
        db.update("UPDATE payment_styles SET name=? WHERE id=?",name,id);return id;
    }
    private static long historyId(String value) {
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException malformed) {
            throw new AssertionError("History must expose its numeric database revision id", malformed);
        }
    }
    private void login(Set<String> permissions) {
        var principal=new AuthUser(actor,employee,"payment-workspace",permissions,false,true,false,false,null,UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"",principal.getAuthorities()));
    }
    private String text(String field,UUID id) {return db.queryForObject("SELECT "+field+"::text FROM payment_styles WHERE id=?",String.class,id);}
    private long history(String table) {return db.queryForObject("SELECT count(*) FROM "+table+" WHERE actor_id=?",Long.class,actor);}
    private long versions(UUID id) {return db.queryForObject("SELECT count(*) FROM master_record_versions WHERE entity_type='payment-styles' AND record_id=?",Long.class,id);}
    private static void route(String path,String method) {RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(new MockHttpServletRequest(method,path)));}
}
