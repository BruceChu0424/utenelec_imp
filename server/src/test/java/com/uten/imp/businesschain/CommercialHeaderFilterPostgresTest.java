package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
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
import org.springframework.test.web.servlet.MockMvc;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Native draft read projections exercise real SQL/controller/filter/facet scope.
 * These fixtures do not claim financial posting or inventory-write acceptance. */
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
class CommercialHeaderFilterPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired DocNumberService numbers;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    record Setup(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,Authentication actor){}

    @Test void quoteUsesLocalAmountAndDeliveryNotValidityAndListFacetShareTheExactPredicate()throws Exception {
        var setup=setup();String first=quote(setup,"1000","12.1234",10,1),second=quote(setup,"10","30.1234",2,30);
        var threshold=db.queryForObject("SELECT (CURRENT_DATE+5)::text",String.class);
        var params=Map.of("clientId",setup.world().clientId().toString(),"currencyId",setup.world().currencyId().toString(),
                "hf.amountMin","12.1234","hf.amountMax","12.1234","hf.deliverFrom",threshold);
        JsonNode list=read("/api/sales/quotes",setup.actor(),params,200);
        assertEquals(1,list.path("total").asInt());assertEquals(first,list.path("items").get(0).path("billNo").asText());
        JsonNode facet=read("/api/sales/quotes/facets",setup.actor(),params,200);
        assertEquals(1,facet.path("billNo").size());assertEquals(first,facet.path("billNo").get(0).path("value").asText());
        assertNotEquals(first,second);
    }
    @Test void maskedAmountNullAndMalformedAmountProbesAreDeniedOnBothListAndFacet()throws Exception {
        var setup=setup();quote(setup,"100","12",10,30);
        Authentication viewer=principal(setup.world().superAdminUserId(),setup.world().employeeId(),Set.of("sales_quote:view"));
        for(String endpoint:List.of("/api/sales/quotes","/api/sales/quotes/facets"))
            for(Map<String,String> filter:List.of(Map.of("hf.amountNull","true"),Map.of("hf.amountMin","NaN")))
                read(endpoint,viewer,filter,403);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM sales_quotes WHERE client_id=?",Integer.class,setup.world().clientId()));
    }
    @Test void orderOriginalRangeRequiresCurrencyAndCannotSilentlyMatchLocalAmount()throws Exception {
        var setup=setup();String bill=numbers.nextNumber(DocNumberPrefix.SALES_ORDER);
        db.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,total_original,total_local,status,maker_id) VALUES(?,?,CURRENT_DATE,?,?,1,10,1000,0,?)",
                UUID.randomUUID(),bill,setup.world().clientId(),setup.world().currencyId(),setup.world().employeeId());
        read("/api/sales/orders",setup.actor(),Map.of("hf.amountMin","9"),422);
        JsonNode wrong=read("/api/sales/orders",setup.actor(),Map.of("clientId",setup.world().clientId().toString(),"currencyId",setup.world().currencyId().toString(),"hf.amountMin","900"),200);
        assertEquals(0,wrong.path("total").asInt());
        JsonNode exact=read("/api/sales/orders",setup.actor(),Map.of("clientId",setup.world().clientId().toString(),"currencyId",setup.world().currencyId().toString(),"hf.amountMin","10","hf.amountMax","10"),200);
        assertEquals(1,exact.path("total").asInt());assertEquals(bill,exact.path("items").get(0).path("billNo").asText());
    }
    @Test void financeKnownZeroAndUnknownStayDistinctAndLegacyOriginSharesFacetScope()throws Exception {
        var setup=setup();String zero=expense(setup,"0",null),unknown=expense(setup,null,null),legacy=expense(setup,"8",Integer.MAX_VALUE-1000);
        JsonNode known=read("/api/finance/expenses",setup.actor(),Map.of("hf.amountMin","0","hf.amountMax","0","hf.recordOrigin","CURRENT"),200);
        assertTrue(containsBill(known,zero));assertFalse(containsBill(known,unknown));assertFalse(containsBill(known,legacy));
        JsonNode missing=read("/api/finance/expenses",setup.actor(),Map.of("hf.amountNull","true","hf.recordOrigin","CURRENT"),200);
        assertTrue(containsBill(missing,unknown));assertFalse(containsBill(missing,zero));
        JsonNode imported=read("/api/finance/expenses/facets",setup.actor(),Map.of("hf.recordOrigin","LEGACY","hf.amountMin","8","hf.amountMax","8"),200);
        assertTrue(imported.path("billNo").toString().contains(legacy));
        read("/api/finance/expenses",setup.actor(),Map.of("hf.amountNull","true","hf.amountMin","0"),422);
    }
    @Test void wasteWeightNullAndRealZeroUsePhysicalWeightWithoutExposingSuggestionMoney()throws Exception {
        var setup=setup();String zero=waste(setup,"0"),unknown=waste(setup,null);
        JsonNode actual=read("/api/subcontract/wastes",setup.actor(),Map.of("supplierId",setup.world().supplierId().toString(),"hf.weightMin","0","hf.weightMax","0"),200);
        assertTrue(containsBill(actual,zero));assertFalse(containsBill(actual,unknown));
        JsonNode missing=read("/api/subcontract/wastes",setup.actor(),Map.of("supplierId",setup.world().supplierId().toString(),"hf.weightNull","true"),200);
        assertTrue(containsBill(missing,unknown));assertFalse(containsBill(missing,zero));
        read("/api/subcontract/wastes",setup.actor(),Map.of("hf.amountMin","0"),403);
    }
    @Test void wrongOwnerAndDeletedDefaultScopesCannotBeBypassedByTheHeaderFilters()throws Exception {
        var setup=setup();String own=expense(setup,"8",null);
        UUID stranger=setup.fixture().createUserWithPerms(setup.world(),"hf-stranger-"+UUID.randomUUID(),"finance_expense:view");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,stranger);
        Authentication other=principal(stranger,employee,Set.of("finance_expense:view"));
        assertFalse(containsBill(read("/api/finance/expenses",other,Map.of("hf.amountMin","8","hf.amountMax","8"),200),own));
        db.update("UPDATE finance_expenses SET is_deleted=TRUE,deleted_at=now() WHERE bill_no=?",own);
        assertFalse(containsBill(read("/api/finance/expenses",setup.actor(),Map.of("billNo",own,"hf.amountMin","8"),200),own));
        assertTrue(containsBill(read("/api/finance/expenses",setup.actor(),Map.of("billNo",own,"onlyDeleted","true","hf.amountMin","8"),200),own));
    }
    @Test void allTwentyTwoNativeListAndFacetMappingsBuildRealPredicatesUnderTheSameContract()throws Exception {
        var setup=setup();String nowhere="HF-NO-MATCH-"+UUID.randomUUID();
        List<String> paths=List.of("sales/quotes","sales/orders","sales/shipments","sales/other-shipments","sales/returns",
                "purchase/requests","purchase/orders","purchase/receipts","purchase/returns",
                "subcontract/applications","subcontract/inquiries","subcontract/orders","subcontract/material-issues",
                "subcontract/material-returns","subcontract/receipts","subcontract/returns","subcontract/wastes",
                "finance/receipts","finance/payments","finance/expenses","finance/incomes","finance/bank-transfers");
        for(String path:paths) {
            Map<String,String> controls=new java.util.LinkedHashMap<>();controls.put("keyword",nowhere);
            boolean money=!Set.of("purchase/requests","subcontract/applications","subcontract/material-issues","subcontract/material-returns","subcontract/wastes").contains(path);
            if(money){controls.put("hf.amountMin","0");controls.put("hf.amountMax","1");controls.put("hf.amountNull","false");}
            if(Set.of("sales/quotes","sales/orders").contains(path)){controls.put("hf.deliverFrom","2026-01-01");controls.put("hf.deliverTo","2026-12-31");}
            if(Set.of("sales/quotes","sales/orders","sales/other-shipments","sales/returns").contains(path))
                controls.put("currencyId",setup.world().currencyId().toString());
            if(path.equals("subcontract/returns"))controls.put("hf.apPosted","false");
            if(path.equals("subcontract/wastes")){controls.put("hf.weightMin","0");controls.put("hf.weightMax","1");controls.put("hf.weightNull","false");}
            if(path.startsWith("finance/"))controls.put("hf.recordOrigin","CURRENT");
            JsonNode page=read("/api/"+path,setup.actor(),controls,200);assertEquals(0,page.path("total").asInt(),path);
            JsonNode facet=read("/api/"+path+"/facets",setup.actor(),controls,200);
            assertEquals(0,facet.path("billNo").size(),path+" facets preserve keyword and the fixed predicates");
        }
    }
    @Test void importedReturnApReversalFlagHasAnActualBooleanPredicateOnBothListAndFacet()throws Exception {
        var setup=setup();String no=numbers.nextNumber(DocNumberPrefix.SUB_RETURN),yes=numbers.nextNumber(DocNumberPrefix.SUB_RETURN);
        // Imported read projections carry their original AP flags; this fixture does not claim new financial postings.
        db.update("INSERT INTO subcontract_returns(id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,status,ap_posted,legacy_id) VALUES(?,?,CURRENT_DATE,?,?,?,0,FALSE,?)",
                UUID.randomUUID(),no,setup.world().supplierId(),setup.world().warehouseId(),setup.world().employeeId(),Integer.MAX_VALUE-1100);
        db.update("INSERT INTO subcontract_returns(id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,status,ap_posted,legacy_id) VALUES(?,?,CURRENT_DATE,?,?,?,1,TRUE,?)",
                UUID.randomUUID(),yes,setup.world().supplierId(),setup.world().warehouseId(),setup.world().employeeId(),Integer.MAX_VALUE-1101);
        var positive=Map.of("supplierId",setup.world().supplierId().toString(),"hf.apPosted","true");
        JsonNode page=read("/api/subcontract/returns",setup.actor(),positive,200);assertTrue(containsBill(page,yes));assertFalse(containsBill(page,no));
        JsonNode facet=read("/api/subcontract/returns/facets",setup.actor(),positive,200);assertTrue(facet.path("billNo").toString().contains(yes));assertFalse(facet.path("billNo").toString().contains(no));
    }

    private Setup setup(){var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("hf-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());return new Setup(fixture,world,SecurityContextHolder.getContext().getAuthentication());}
    private String quote(Setup s,String original,String local,int deliveryDays,int validityDays){String bill=numbers.nextNumber(DocNumberPrefix.SALES_QUOTE);db.update("INSERT INTO sales_quotes(id,bill_no,bill_date,client_id,currency_id,maker_id,status,total_original,total_local,deliver_date,valid_until) VALUES(?,?,CURRENT_DATE,?,?,?,0,?,?,CURRENT_DATE+?,CURRENT_DATE+?)",UUID.randomUUID(),bill,s.world().clientId(),s.world().currencyId(),s.world().employeeId(),new BigDecimal(original),new BigDecimal(local),deliveryDays,validityDays);return bill;}
    private String expense(Setup s,String amount,Integer legacy)throws Exception {
        String bill=numbers.nextNumber(DocNumberPrefix.FIN_EXPENSE);
        if(legacy==null) {
            db.update("INSERT INTO finance_expenses(id,bill_no,bill_date,maker_id,status,amount_original,amount_local) VALUES(?,?,CURRENT_DATE,?,0,?,?)",
                    UUID.randomUUID(),bill,s.world().employeeId(),amount==null?null:new BigDecimal(amount),amount==null?null:new BigDecimal(amount));
            return bill;
        }
        // Complete typed synthetic source through the real import capability:
        // never forge legacy_id or disable the permanent provenance guard.
        com.fasterxml.jackson.databind.node.ObjectNode source;
        try(var input=new org.springframework.core.io.ClassPathResource("legacy-bootstrap-fixture/variants/finance-facts.json").getInputStream()) {
            source=(com.fasterxml.jackson.databind.node.ObjectNode)json.readTree(input).path("m_dpaid.csv").get(0).deepCopy();
        }
        for(String key:List.of("cancel_date","invoices_no","remark","source"))if(!source.has(key))source.putNull(key);
        source.put("legacy_id",legacy);source.put("bill_no",bill);source.put("total",new BigDecimal(amount));source.put("mtotal",new BigDecimal(amount));
        try(var connection=db.getDataSource().getConnection()) {
            connection.setAutoCommit(false);
            var imported=new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            UUID run=com.uten.imp.support.LegacyFinanceImportFixture.context(imported);
            UUID id=imported.queryForObject("SELECT fn_import_legacy_finance_source(?,?,?::jsonb)",UUID.class,run,"EXPENSE",source.toString());
            assertNotNull(id);
            imported.update("UPDATE legacy_migration_runs SET status='SUCCESS' WHERE run_id=?",run);
            assertEquals(1,imported.queryForObject("SELECT count(*) FROM legacy_finance_import_sources WHERE target_id=? AND source_kind='EXPENSE'",Integer.class,id));
            connection.commit();
        }
        return bill;
    }
    private String waste(Setup s,String weight){String bill=numbers.nextNumber(DocNumberPrefix.SUB_WASTE);db.update("INSERT INTO subcontract_wastes(id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,status,total_weight) VALUES(?,?,CURRENT_DATE,?,?,?,0,?)",UUID.randomUUID(),bill,s.world().supplierId(),s.world().warehouseId(),s.world().employeeId(),weight==null?null:new BigDecimal(weight));return bill;}
    private Authentication principal(UUID id,UUID employee,Set<String> permissions){var user=new AuthUser(id,employee,"header-scope",permissions,false,true,false);return new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities());}
    private JsonNode read(String path,Authentication actor,Map<String,String> params,int expected)throws Exception{var request=get(path).with(authentication(actor));params.forEach(request::param);var response=http.perform(request).andReturn().getResponse();assertEquals(expected,response.getStatus(),response.getContentAsString());SecurityContextHolder.getContext().setAuthentication(actor);return json.readTree(response.getContentAsByteArray());}
    private boolean containsBill(JsonNode page,String bill){for(JsonNode item:page.path("items"))if(bill.equals(item.path("billNo").asText()))return true;return false;}
}
