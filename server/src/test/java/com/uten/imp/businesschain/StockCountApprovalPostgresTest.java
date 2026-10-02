package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.count.StockCountDtos;
import com.uten.imp.features.stock.count.StockCountRequestController;
import com.uten.imp.features.stock.count.StockCountRequestService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.workshop-material.auto-close.enabled=false"})
class StockCountApprovalPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired StockCountRequestController controller;
    @Autowired StockCountRequestService service;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID maker,finance,warehouseReviewer,outsider;
    @BeforeEach void seed(){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("count-approval-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        maker=fixture.createUserWithPerms(world,"counter-"+UUID.randomUUID(),"stock:view","stock:count:submit");
        finance=fixture.createUserWithPerms(world,"count-finance-"+UUID.randomUUID(),"stock:count:finance_review");
        warehouseReviewer=fixture.createUserWithPerms(world,"count-wh-"+UUID.randomUUID(),"stock:count:warehouse_review");
        outsider=fixture.createUserWithPerms(world,"count-none-"+UUID.randomUUID(),"stock:view");
        inbound(world.goodsA(),"10");
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void submitDoesNotPostAndOnlyFinanceApprovalAppliesTheNormalWarehouseSnapshot(){
        fixture.loginAs(maker);var input=input(world.goodsA(),"14",null,false);
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"现场盘点",key(),List.of(input)));
        UUID id=(UUID)request.get("id");assertEquals("PENDING",request.get("status"));assertEquals("FINANCE",request.get("reviewRoute"));qty("10");
        assertNull(request.get("stockDocumentId"));
        fixture.loginAs(warehouseReviewer);
        assertThrows(ApiException.class,()->controller.approve(id,new StockCountDtos.Decision(0L,key(),null)));qty("10");
        fixture.loginAs(maker);
        assertThrows(ApiException.class,()->controller.approve(id,new StockCountDtos.Decision(0L,key(),null)));qty("10");
        fixture.loginAs(finance);String command=key();
        var approved=controller.approve(id,new StockCountDtos.Decision(0L,command,null));
        assertEquals("APPROVED",approved.get("status"));assertNotNull(approved.get("stockDocumentId"));qty("14");
        assertEquals(approved.get("stockDocumentId"),controller.approve(id,new StockCountDtos.Decision(0L,command,null)).get("stockDocumentId"));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_count_request_events WHERE request_id=? AND action='APPROVE'",Integer.class,id));
    }

    @Test void rejectsUnauthorizedEntryAndRejectOrCancelNeverChangesBalances(){
        fixture.loginAs(outsider);assertThrows(AccessDeniedException.class,()->controller.scope(null));
        fixture.loginAs(maker);var input=input(world.goodsA(),"15",null,false);
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"重新清点",key(),List.of(input)));
        UUID id=(UUID)request.get("id");fixture.loginAs(finance);
        assertThrows(ApiException.class,()->controller.reject(id,new StockCountDtos.Decision(0L,key()," ")));
        assertEquals("REJECTED",controller.reject(id,new StockCountDtos.Decision(0L,key(),"差额需复核")).get("status"));qty("10");
        fixture.loginAs(maker);var second=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"复核",key(),List.of(input)));
        UUID secondId=(UUID)second.get("id");
        assertEquals("CANCELLED",controller.cancel(secondId,new StockCountDtos.Decision(0L,key(),null)).get("status"));qty("10");
    }

    @Test void interveningReceiptRejectsApprovalAtomicallyAndLeavesTheRequestPending(){
        fixture.loginAs(maker);var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"等待审核",key(),List.of(input(world.goodsA(),"20",null,false))));
        UUID id=(UUID)request.get("id");fixture.loginAs(world.superAdminUserId());inbound(world.goodsA(),"2");
        fixture.loginAs(finance);assertThrows(ApiException.class,()->controller.approve(id,new StockCountDtos.Decision(0L,key(),null)));
        qty("12");assertEquals("PENDING",controller.detail(id).get("status"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_count_request_events WHERE request_id=? AND action='APPROVE'",Integer.class,id));
        assertNull(controller.detail(id).get("stockDocumentId"));
    }

    @Test void aMultiLineApprovalRollsBackEveryLineWhenOneSnapshotChanged(){
        fixture.loginAs(world.superAdminUserId());inbound(world.goodsB(),"5");
        fixture.loginAs(maker);var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"两种盘点",key(),
                List.of(input(world.goodsA(),"20",null,false),input(world.goodsB(),"8",null,false))));
        fixture.loginAs(world.superAdminUserId());inbound(world.goodsB(),"1");
        fixture.loginAs(finance);assertThrows(ApiException.class,()->controller.approve((UUID)request.get("id"),new StockCountDtos.Decision(0L,key(),null)));
        qty("10");assertEquals("PENDING",controller.detail((UUID)request.get("id")).get("status"));
    }

    @Test void weightOnlyEditsAreReviewedAndStaleWeightsCannotBeOverwritten(){
        fixture.loginAs(maker);var before=input(world.goodsA(),"10","2.5000",true);
        var proposal=new StockCountDtos.Submit(world.warehouseId(),"实称净重",key(),List.of(before));
        var request=controller.submit(proposal);UUID id=(UUID)request.get("id");
        assertEquals(id,controller.submit(proposal).get("id"));
        assertThrows(ApiException.class,()->controller.submit(new StockCountDtos.Submit(world.warehouseId(),"changed",proposal.idempotencyKey(),List.of(before))));
        fixture.loginAs(finance);controller.approve(id,new StockCountDtos.Decision(0L,key(),null));qty("10");
        assertEquals(0,new BigDecimal("2.5").compareTo(db.queryForObject("SELECT weight FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,world.warehouseId(),world.goodsA())));
        fixture.loginAs(maker);var stale=input(world.goodsA(),"10","3",true);
        var second=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"另一称量",key(),List.of(stale)));
        var third=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"先核准另一称量",key(),List.of(input(world.goodsA(),"10","4",true))));
        fixture.loginAs(finance);controller.approve((UUID)third.get("id"),new StockCountDtos.Decision(0L,key(),null));
        assertThrows(ApiException.class,()->controller.approve((UUID)second.get("id"),new StockCountDtos.Decision(0L,key(),null)));
    }

    @Test void candidatesIncludeZeroStockAndNeverAcceptAggregateWarehouse(){
        fixture.loginAs(maker);var rows=controller.candidates(world.warehouseId(),"",List.of(world.goodsB()),1,50).getItems();
        assertFalse(rows.isEmpty());assertEquals(0,new BigDecimal(rows.getFirst().get("qty").toString()).signum());
        assertThrows(ApiException.class,()->controller.candidates(UUID.randomUUID(),"",null,1,50));
    }

    @Test void disabledWarehouseRemainsReviewableForRejectionButCannotBePosted(){
        fixture.loginAs(maker);var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"停用前盘点",key(),
                List.of(input(world.goodsA(),"12",null,false))));
        UUID id=(UUID)request.get("id");db.update("UPDATE warehouses SET status='禁用' WHERE id=?",world.warehouseId());
        fixture.loginAs(finance);
        assertEquals("PENDING",controller.detail(id).get("status"));
        assertTrue(controller.list("FINANCE","PENDING",world.warehouseId(),1,50).getItems().stream().anyMatch(r->id.equals(r.get("id"))));
        assertThrows(ApiException.class,()->controller.approve(id,new StockCountDtos.Decision(0L,key(),null)));
        assertEquals("REJECTED",controller.reject(id,new StockCountDtos.Decision(0L,key(),"仓库已停用，请重新核对")).get("status"));
        qty("10");
    }

    @Test void aggregateCountsMatchScopedListsAcrossRolesAndFinalStates() {
        fixture.loginAs(maker);
        var line=input(world.goodsA(),"12",null,false);
        var pending=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"pending",key(),List.of(line)));
        var rejected=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"rejected",key(),List.of(line)));
        var cancelled=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"cancelled",key(),List.of(line)));
        controller.cancel((UUID)cancelled.get("id"),new StockCountDtos.Decision(0L,key(),null));
        fixture.loginAs(finance);
        controller.reject((UUID)rejected.get("id"),new StockCountDtos.Decision(0L,key(),"recheck"));
        db.update("UPDATE warehouses SET status='禁用' WHERE id=?",world.warehouseId());
        for (UUID actor:List.of(maker,finance,warehouseReviewer,world.superAdminUserId())) {
            fixture.loginAs(actor);
            var actual=controller.counts();
            boolean admin=actor.equals(world.superAdminUserId());
            assertEquals(admin||actor.equals(finance)?controller.list("FINANCE","PENDING",null,1,1).getTotal():0L,actual.get("financePending"));
            assertEquals(admin||actor.equals(warehouseReviewer)?controller.list("WAREHOUSE","PENDING",null,1,1).getTotal():0L,actual.get("warehousePending"));
            assertEquals(admin||actor.equals(maker)?controller.list(null,"PENDING",null,1,1).getTotal():0L,actual.get("myPending"));
            assertEquals(admin||actor.equals(maker)?controller.list(null,"REJECTED",null,1,1).getTotal():0L,actual.get("myRejected"));
        }
        fixture.loginAs(maker);
        assertEquals(1L,controller.counts().get("myPending"));
        assertEquals(1L,controller.counts().get("myRejected"));
        assertEquals("PENDING",controller.detail((UUID)pending.get("id")).get("status"));
        fixture.loginAs(outsider);
        assertThrows(AccessDeniedException.class,controller::counts);
    }

    private StockCountDtos.LineInput input(UUID goods,String qty,String weight,boolean weightChanged){
        var rows=controller.candidates(world.warehouseId(),"",List.of(goods),1,50).getItems();
        var row=rows.stream().filter(r->r.get("colorId")==null).findFirst().orElseThrow();
        return new StockCountDtos.LineInput(goods,null,(UUID)row.get("unitId"),new BigDecimal(row.get("qty").toString()),
                row.get("weightKg")==null?null:new BigDecimal(row.get("weightKg").toString()),Boolean.TRUE.equals(row.get("weightEstimated")),
                new BigDecimal(qty),weight==null?null:new BigDecimal(weight),weightChanged,null,((Number)row.get("goodsVersion")).longValue());
    }
    private void inbound(UUID goods,String qty){
        StockDocSaveRequest request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(world.warehouseId());request.setBillDate(BusinessTime.today());
        StockDocItemLine item=new StockDocItemLine();item.setGoodsId(goods);item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(qty));item.setPrice(new BigDecimal("10"));item.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal("10")));
        item.setAmountLocal(item.getAmountOriginal());request.setItems(List.of(item));stock.approve(stock.create(request).getId());
    }
    private void qty(String expected){assertEquals(0,new BigDecimal(expected).compareTo(db.queryForObject(
            "SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,world.warehouseId(),world.goodsA())));}
    private static String key(){return "count-"+UUID.randomUUID();}
}
