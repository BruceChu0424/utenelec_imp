package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real draft replacements/soft deletion retain exact old sources without adding retired quantity to current facts. */
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
class ProductionStockRecordHistoryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionDailyReportService reports;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void stockReplacementAndDeletedHistoryKeepExactOriginalMoneyAndNeverRepeatLiveQuantity()throws Exception {
        var fixture=fixture();var world=fixture.seedWorld("retain-stock-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        var original=stock.create(stockRequest(world,"3"));UUID oldItem=original.getItems().getFirst().getId();
        String oldJson=db.queryForObject("SELECT to_jsonb(i)::text FROM stock_document_items i WHERE id=?",String.class,oldItem);
        stock.update(original.getId(),stockRequest(world,"7"));
        assertEquals(oldJson,db.queryForObject("SELECT payload::text FROM business_record_history WHERE source_table='stock_document_items' AND source_id=? AND operation='DELETE'",String.class,oldItem.toString()));
        equal("7",db.queryForObject("SELECT sum(qty) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",BigDecimal.class,original.getId()));
        var retained=stock.historyRecords(original.getId(),null,20);assertEquals(1,retained.size());
        assertTrue(retained.getFirst().originalJson().contains("9876543210123.1234"));
        equal("9876543210123.1234",retained.getFirst().original().path("price").decimalValue());
        stock.delete(original.getId());
        JsonNode history=read("/api/stock/docs/"+original.getId()+"/history",actor,200);
        assertTrue(history.path("deleted").asBoolean());assertTrue(history.path("historyReadOnly").asBoolean());
        assertEquals(0,history.path("status").asInt());assertFalse(history.path("canEdit").asBoolean());assertFalse(history.path("canDelete").asBoolean());
        equal("7",history.path("items").get(0).path("qty").decimalValue());
        read("/api/stock/docs/"+original.getId(),actor,404);
        assertEquals(0,read("/api/stock/docs?docType=OTHER_IN&billNo="+original.getBillNo(),actor,200).path("total").asInt());
        JsonNode only=read("/api/stock/docs?docType=OTHER_IN&onlyDeleted=true&billNo="+original.getBillNo(),actor,200);
        assertEquals(1,only.path("total").asInt());assertTrue(only.path("items").get(0).path("deleted").asBoolean());
    }

    @Test void stockRetainedRowsMaskBothParsedAndRawPriceAndKeepCurrentOwnerScope()throws Exception {
        var fixture=fixture();var world=fixture.seedWorld("retain-mask-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        var original=stock.create(stockRequest(world,"3"));stock.update(original.getId(),stockRequest(world,"4"));stock.delete(original.getId());
        Authentication reader=principal(world.superAdminUserId(),world.employeeId(),Set.of("stock_doc:view"));
        JsonNode rows=read("/api/stock/docs/"+original.getId()+"/history-records",reader,200);
        assertEquals(1,rows.size());assertFalse(rows.get(0).path("original").has("price"));
        assertFalse(rows.get(0).path("originalJson").asText().contains("amount_original"));
        assertFalse(rows.get(0).path("originalJson").asText().contains("9876543210123.1234"));
        equal("3",rows.get(0).path("original").path("qty").decimalValue());
        UUID stranger=fixture.createUserWithPerms(world,"history-stranger-"+UUID.randomUUID(),"stock_doc:view");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,stranger);
        read("/api/stock/docs/"+original.getId()+"/history",principal(stranger,employee,Set.of("stock_doc:view")),404);
        read("/api/stock/docs/"+original.getId()+"/history-records",principal(stranger,employee,Set.of("stock_doc:view")),404);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE id=?",Integer.class,original.getId()));
    }

    @Test void productionPlanReplacementPreservesLifetimeProductNumberAndOriginalLine()throws Exception {
        var fixture=fixture();var world=fixture.seedWorld("retain-plan-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        var first=plans.create(planRequest(world,"3",null,null));var old=first.getItems().getFirst();
        String original=db.queryForObject("SELECT to_jsonb(i)::text FROM production_plan_items i WHERE id=?",String.class,old.getId());
        var latest=plans.update(first.getId(),planRequest(world,"7",old.getProductNo(),old.getId()));
        equal("7",latest.getItems().getFirst().getQty());assertEquals(old.getProductNo(),latest.getItems().getFirst().getProductNo());
        assertNotEquals(old.getId(),latest.getItems().getFirst().getId());
        assertEquals(original,db.queryForObject("SELECT payload::text FROM business_record_history WHERE source_table='production_plan_items' AND source_id=? AND operation='DELETE'",String.class,old.getId().toString()));
        plans.delete(first.getId());var historical=plans.history(first.getId());
        assertTrue(historical.isDeleted());assertTrue(historical.isHistoryReadOnly());assertTrue(historical.getAllowedActions().isEmpty());
        equal("7",historical.getItems().getFirst().getQty());
        assertThrows(com.uten.imp.common.web.ApiException.class,()->plans.update(first.getId(),planRequest(world,"8",old.getProductNo(),old.getId())));
    }

    @Test void deletedDailyCreateReceiptReturnsKnownOriginalIdentityWithoutCreatingANewReport() {
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","retain-report-"+UUID.randomUUID(),false,"10");
        List<com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        DailyReportSaveRequest firstRequest=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"3","3");
        DailyReportSaveRequest frozen=json.convertValue(firstRequest,DailyReportSaveRequest.class);
        var first=reports.create(firstRequest);UUID oldItem=first.getItems().getFirst().getId();
        DailyReportSaveRequest edit=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"4","4");
        edit.setExpectedVersion(first.getRowVersion());reports.update(first.getId(),edit);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM business_record_history WHERE source_table='production_daily_report_items' AND source_id=? AND operation='DELETE'",Integer.class,oldItem.toString()));
        assertTrue(db.queryForObject("SELECT count(*) FROM business_record_history WHERE parent_table='production_daily_reports' AND parent_id=? AND source_table='production_daily_report_material_usages'",Integer.class,first.getId().toString())>0);
        reports.delete(first.getId());var replay=reports.create(frozen);
        assertEquals(first.getId(),replay.getId());assertTrue(replay.isDeleted());assertTrue(replay.isHistoryReadOnly());assertTrue(replay.getAllowedActions().isEmpty());
        equal("4",replay.getItems().getFirst().getQty());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE actor_user_id=? AND idempotency_key=?",Integer.class,
                ((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getId(),frozen.getIdempotencyKey()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_settlement_events WHERE daily_report_id=?",Integer.class,first.getId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=?",Integer.class,first.getId()));
    }

    private FullChainEndToEndTest fixture(){var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);return fixture;}
    private StockDocSaveRequest stockRequest(FullChainEndToEndTest.World world,String quantity){var row=new StockDocItemLine();row.setGoodsId(world.goodsD());row.setUnitId(world.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(new BigDecimal(quantity));
        row.setPrice(new BigDecimal("9876543210123.1234"));row.setAmountOriginal(row.getQty().multiply(row.getPrice()));row.setAmountLocal(row.getAmountOriginal());
        var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setBillDate(BusinessTime.today());request.setWarehouseId(world.warehouseId());request.setItems(List.of(row));return request;}
    private PlanSaveRequest planRequest(FullChainEndToEndTest.World world,String quantity,String product,UUID source){var row=new PlanItemLine();row.setGoodsId(world.goodsA());row.setUnitId(world.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(new BigDecimal(quantity));row.setProductNo(product);row.setSourceItemId(source);
        var request=new PlanSaveRequest();request.setBillDate(BusinessTime.today());request.setDepartmentId(world.departmentId());request.setItems(List.of(row));return request;}
    private Authentication principal(UUID id,UUID employee,Set<String> permissions){var user=new AuthUser(id,employee,"history-view",permissions,false,true,false);return new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities());}
    private JsonNode read(String path,Authentication actor,int expected)throws Exception{var result=http.perform(get(path).with(authentication(actor))).andReturn().getResponse();assertEquals(expected,result.getStatus(),result.getContentAsString());SecurityContextHolder.getContext().setAuthentication(actor);return json.readTree(result.getContentAsByteArray());}
    private void equal(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
