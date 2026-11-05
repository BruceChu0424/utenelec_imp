package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.features.finance.payables.ProcurementPayableRecognitionService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpMethod;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.request;

/** Owning MVC converter/controller plus real services/transactions/current DDL.
 * Authentication filters have their separate contract; this fixture supplies a
 * real authorized current principal and never bypasses method/domain scopes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.inventory.value-work.enabled=false","uten.workshop-material.auto-close.enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceConfigurationWirePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceConfigurationWirePostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired WebApplicationContext context;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired GlReportLineBindingService bindings;
    @Autowired ProcurementPayableRecognitionService ap;
    @Autowired InventoryCostPostingService inventory;
    private MockMvc http;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private record Endpoint(String operation,String method,String path,String receipt,Class<?> type,List<String> required) { }
    private static final String AP="/finance/procurement-payable-recognitions/policy",INV="/finance/gl/inventory-cost",GL="/finance/reports/gl/line-bindings";
    private record OldAp(UUID requestId,long expectedRevision,boolean enabled,LocalDate effectiveFrom,String sourceReference) { }
    private record OldInventory(UUID requestId,boolean enabled,LocalDate effectiveFrom,String reconciliationReference,long expectedVersion) { }
    private record OldBinding(UUID requestId,List<UUID> targetIds,boolean confirmedZero,String expectedFingerprint) { }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void exactNullAndMissingWireCanNeverAcquireDefaultsOrClearBindingsAndCanBePermanentlySealed()throws Exception{
        http=MockMvcBuilders.webAppContextSetup(context).build();fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("configuration-wire-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
        assertThat(((Number)ap.policy().get("revision")).longValue()).isZero();assertThat(inventory.policy().version()).isZero();
        UUID apId=UUID.randomUUID();ObjectNode apValid=object(new OldAp(apId,0,false,null,"匿名明确停用原政策"));
        var first=call("PUT",AP,apValid,200);assertThat(first).containsEntry("outcome","SUCCEEDED");assertHash(apId,"PROCUREMENT_AP_POLICY_SAVE","PUT",AP,new OldAp(apId,0,false,null,"匿名明确停用原政策"));
        UUID invId=UUID.randomUUID();ObjectNode invValid=object(new OldInventory(invId,false,null,"匿名明确停用原库存策略",0));
        call("PUT",INV+"/policy",invValid,200);assertHash(invId,"INVENTORY_COST_POLICY_SAVE","PUT",INV+"/policy",new OldInventory(invId,false,null,"匿名明确停用原库存策略",0));
        UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?,'EXPENSE',0,'使用')",style,"WIRE-"+style,"匿名原绑定-"+style);
        String fingerprint=binding().stateFingerprint();UUID bindingId=UUID.randomUUID();ObjectNode bound=object(new OldBinding(bindingId,List.of(style),false,fingerprint));
        call("PUT",GL+"/OP_RENT",bound,200);assertHash(bindingId,"GL_REPORT_BINDING_REPLACE","PUT",GL+"/OP_RENT",new OldBinding(bindingId,List.of(style),false,fingerprint));
        long apVersion=((Number)ap.policy().get("revision")).longValue(),inventoryVersion=inventory.policy().version();String before=binding().stateFingerprint();
        long periods=db.queryForObject("SELECT count(*) FROM inventory_cost_gl_periods",Long.class);
        var endpoints=List.of(
            new Endpoint("PROCUREMENT_AP_POLICY_SAVE","PUT",AP,AP+"/operations",ProcurementPayableRecognitionService.PolicyCommand.class,List.of("expectedRevision","enabled")),
            new Endpoint("INVENTORY_COST_POLICY_SAVE","PUT",INV+"/policy",INV+"/operations",InventoryCostPostingService.PolicyCommand.class,List.of("enabled","expectedVersion")),
            new Endpoint("GL_REPORT_BINDING_REPLACE","PUT",GL+"/OP_RENT",GL+"/operations",GlReportLineBindingService.ReplaceCommand.class,List.of("targetIds","confirmedZero")),
            new Endpoint("INVENTORY_COST_CLOSE","POST",INV+"/periods/2093-03/close",INV+"/operations",InventoryCostPostingService.CloseCommand.class,List.of("expectedVersion")));
        for(var endpoint:endpoints)for(String field:endpoint.required())for(boolean missing:List.of(false,true)){
            UUID id=UUID.randomUUID();ObjectNode body=switch(endpoint.operation()){
                case "PROCUREMENT_AP_POLICY_SAVE"->object(new ProcurementPayableRecognitionService.PolicyCommand(id,apVersion,false,null,"匿名完整原政策依据"));
                case "INVENTORY_COST_POLICY_SAVE"->object(new InventoryCostPostingService.PolicyCommand(id,false,null,"匿名完整原库存依据",inventoryVersion));
                case "GL_REPORT_BINDING_REPLACE"->object(new GlReportLineBindingService.ReplaceCommand(id,List.of(style),false,before));
                default->object(new InventoryCostPostingService.CloseCommand(id,0,"匿名原关期原因"));
            };
            if(missing)body.remove(field);else body.putNull(field);
            call(endpoint.method(),endpoint.path(),body,422);assertThat(receipts(id)).isZero();
            var cancellation=Map.of("requestId",id,"actorId",world.superAdminUserId(),"operation",endpoint.operation(),"method",endpoint.method(),"path",endpoint.path(),"requestBody",body);
            var stopped=call("POST",endpoint.receipt()+"/"+id+"/cancel",cancellation,200);assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(stopped.get("requestBody"),body);
            var late=call(endpoint.method(),endpoint.path(),body,200);same(late,stopped);
            var changed=body.deepCopy();if(missing)changed.putNull(field);else changed.remove(field);
            call("POST",endpoint.receipt()+"/"+id+"/cancel",Map.of("requestId",id,"actorId",world.superAdminUserId(),"operation",endpoint.operation(),"method",endpoint.method(),"path",endpoint.path(),"requestBody",changed),409);
            assertThat(receipts(id)).isEqualTo(1);assertThat(((Number)ap.policy().get("revision")).longValue()).isEqualTo(apVersion);assertThat(inventory.policy().version()).isEqualTo(inventoryVersion);assertThat(binding().stateFingerprint()).isEqualTo(before);
            assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_periods",Long.class)).isEqualTo(periods);
        }
        UUID malformed=UUID.randomUUID();ObjectNode bad=object(new OldAp(malformed,apVersion,false,null,"匿名错误字段类型"));bad.put("enabled","false");
        call("PUT",AP,bad,400);assertThat(receipts(malformed)).isZero();
        call("POST",AP+"/operations/"+malformed+"/cancel",Map.of("requestId",malformed,"actorId",world.superAdminUserId(),"operation","PROCUREMENT_AP_POLICY_SAVE","method","PUT","path",AP,"requestBody",bad),200);
        call("PUT",AP,bad,400);assertThat(((Number)ap.policy().get("revision")).longValue()).isEqualTo(apVersion);
        UUID clear=UUID.randomUUID();call("PUT",GL+"/OP_RENT",object(new OldBinding(clear,List.of(),false,before)),200);assertThat(binding().targets()).isEmpty();
        assertThat(new InventoryCostPostingService.CloseCommand(UUID.randomUUID(),0,"原0版本").expectedVersion()).isZero();
    }
    private GlReportLineBindingService.LineBinding binding(){return bindings.list().stream().filter(row->row.lineKey().equals("OP_RENT")).findFirst().orElseThrow();}
    private ObjectNode object(Object value){return json.valueToTree(value);}
    private int receipts(UUID id){return db.queryForObject("SELECT count(*) FROM finance_application_operations WHERE request_id=?",Integer.class,id);}
    private Map<String,Object> call(String method,String path,Object body,int status)throws Exception{
        var response=http.perform(request(HttpMethod.valueOf(method),"/api"+path).contentType("application/json").content(json.writeValueAsString(body))).andReturn().getResponse();
        assertThat(response.getStatus()).as(method+" "+path).isEqualTo(status);return FinancialJsonResults.object(json,response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8));
    }
    private void assertHash(UUID id,String operation,String method,String path,Object oldBody)throws Exception{
        var payload=new LinkedHashMap<String,Object>();payload.put("method",method);payload.put("path",path);payload.put("requestBody",oldBody);
        String expected=ImmutableDocumentStore.digest(json.writeValueAsBytes(Arrays.asList(operation,null,payload)));
        assertThat(db.queryForObject("SELECT payload_hash FROM finance_application_operations WHERE request_id=?",String.class,id)).isEqualTo(expected);
    }
    private void same(Object actual,Object expected)throws Exception{assertThat(FinancialJsonResults.tree(json,json.writeValueAsString(actual))).isEqualTo(FinancialJsonResults.tree(json,json.writeValueAsString(expected)));}
}
