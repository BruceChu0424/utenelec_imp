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

    /**
     * 盘点说明选填(V795/ADR-151): 不传、空串、只有空白都能送审, 统一存成 ""; 同一提交编号的不同空白写法
     * 是同一次提交(重放返回同一单), 财务审核照常过账。2026-10-04 线上曾因 V766 约束要求至少 1 个字而 409。
     */
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.NullAndEmptySource
    @org.junit.jupiter.params.provider.ValueSource(strings={"   ","\t\n"})
    void blankExplanationIsOptionalStoredEmptyAndStillPostsAfterFinanceApproval(String reason){
        fixture.loginAs(maker);var input=input(world.goodsA(),"13",null,false);String command=key();
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),reason,command,List.of(input)));
        UUID id=(UUID)request.get("id");assertEquals("PENDING",request.get("status"));
        assertEquals("",db.queryForObject("SELECT reason FROM stock_count_requests WHERE id=?",String.class,id));
        assertEquals("",db.queryForObject("SELECT reason FROM stock_count_request_events WHERE request_id=? AND action='SUBMIT'",String.class,id));
        for(String replay:Arrays.asList(null,""," \t ")){
            assertEquals(id,controller.submit(new StockCountDtos.Submit(world.warehouseId(),replay,command,List.of(input))).get("id"),
                    "空白说明的不同写法是同一次提交");
        }
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_count_requests WHERE command_key=?",Integer.class,command));
        qty("10");
        fixture.loginAs(finance);
        assertEquals("APPROVED",controller.approve(id,new StockCountDtos.Decision(0L,key(),null)).get("status"));
        qty("13");
    }

    @Test void explanationLongerThan500CharactersIsAPlainValidationError(){
        fixture.loginAs(maker);var input=input(world.goodsA(),"13",null,false);
        var error=assertThrows(ApiException.class,()->controller.submit(
                new StockCountDtos.Submit(world.warehouseId(),"盘".repeat(501),key(),List.of(input))));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,error.getCode());
        assertEquals("盘点说明最多500字",error.getMessage());
        // 去掉首尾空白后正好 500 字是合法的。
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"  "+"盘".repeat(500)+"  ",key(),List.of(input)));
        assertEquals("盘".repeat(500),db.queryForObject("SELECT reason FROM stock_count_requests WHERE id=?",String.class,request.get("id")));
        qty("10");
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

    @Test void countingQuantityToZeroShowsAndPostsDerivedWeightZeroWhileKeepingInputFact(){
        fixture.loginAs(maker);
        var weightRequest=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"先核定库存重量",key(),
                List.of(input(world.goodsA(),"10","2.5000",true))));
        fixture.loginAs(finance);
        controller.approve((UUID)weightRequest.get("id"),new StockCountDtos.Decision(0L,key(),null));
        fixture.loginAs(maker);
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"实盘已无库存",key(),
                List.of(input(world.goodsA(),"0",null,false))));
        UUID id=(UUID)request.get("id");
        @SuppressWarnings("unchecked")
        var line=((List<Map<String,Object>>)request.get("lines")).getFirst();
        assertEquals(Boolean.TRUE,line.get("weightChanged"),"审核展示必须包含数量清零派生的重量清零");
        assertEquals(0,BigDecimal.ZERO.compareTo(new BigDecimal(line.get("targetWeightKg").toString())));
        assertEquals(0,new BigDecimal("-2.5").compareTo(new BigDecimal(line.get("deltaWeightKg").toString())));
        assertEquals(Boolean.FALSE,db.queryForObject("SELECT weight_changed FROM stock_count_request_lines WHERE request_id=?",Boolean.class,id),
                "存储仍保留员工没有单独编辑重量的原始事实");
        qty("10");
        fixture.loginAs(finance);
        var approved=controller.approve(id,new StockCountDtos.Decision(0L,key(),null));
        assertEquals("APPROVED",approved.get("status"));
        qty("0");
        assertEquals(0,BigDecimal.ZERO.compareTo(db.queryForObject(
                "SELECT weight FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class,world.warehouseId(),world.goodsA())));
    }

    @Test void leavingUnknownWeightBlankDoesNotLookLikeClearingItInReview(){
        fixture.loginAs(maker);
        var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"只修数量，重量尚未称",key(),
                List.of(input(world.goodsA(),"12",null,false))));
        @SuppressWarnings("unchecked")
        var line=((List<Map<String,Object>>)request.get("lines")).getFirst();
        assertNull(line.get("beforeWeightKg"));
        assertNull(line.get("targetWeightKg"));
        assertEquals(Boolean.FALSE,line.get("weightChanged"));
        assertNull(line.get("deltaWeightKg"));
        qty("10");
    }

    /**
     * ADR-145: 还有库存的仓不能停用(数据库守卫逐条列出原因), 所以待审盘点不会落在停用仓上;
     * 停用被拒后仓库照常可用, 盘点照常驳回/审核。
     */
    @Test void warehouseHoldingStockCannotBeRetiredWhileItsCountIsPending(){
        fixture.loginAs(maker);var request=controller.submit(new StockCountDtos.Submit(world.warehouseId(),"停用前盘点",key(),
                List.of(input(world.goodsA(),"12",null,false))));
        UUID id=(UUID)request.get("id");
        var refused=assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                ()->db.update("UPDATE warehouses SET status='禁用' WHERE id=?",world.warehouseId()));
        assertTrue(refused.getMessage().contains("现在不能停用"),refused.getMessage());
        assertTrue(refused.getMessage().contains("有库存"),refused.getMessage());
        assertEquals("使用",db.queryForObject("SELECT status FROM warehouses WHERE id=?",String.class,world.warehouseId()));
        fixture.loginAs(finance);
        assertEquals("PENDING",controller.detail(id).get("status"));
        assertTrue(controller.list("FINANCE","PENDING",world.warehouseId(),1,50).getItems().stream().anyMatch(r->id.equals(r.get("id"))));
        assertEquals("REJECTED",controller.reject(id,new StockCountDtos.Decision(0L,key(),"请重新核对")).get("status"));
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
        // ADR-145: the counted warehouse still holds stock, so it cannot be retired; counts and
        // scoped lists are compared on the live warehouse.
        for (UUID actor:List.of(maker,finance,warehouseReviewer,world.superAdminUserId())) {
            fixture.loginAs(actor);
            var actual=controller.counts(null);
            boolean admin=actor.equals(world.superAdminUserId());
            assertEquals(admin||actor.equals(finance)?controller.list("FINANCE","PENDING",null,1,1).getTotal():0L,actual.get("financePending"));
            assertEquals(admin||actor.equals(warehouseReviewer)?controller.list("WAREHOUSE","PENDING",null,1,1).getTotal():0L,actual.get("warehousePending"));
            assertEquals(admin||actor.equals(maker)?controller.list(null,"PENDING",null,1,1).getTotal():0L,actual.get("myPending"));
            assertEquals(admin||actor.equals(maker)?controller.list(null,"REJECTED",null,1,1).getTotal():0L,actual.get("myRejected"));
        }
        fixture.loginAs(maker);
        assertEquals(1L,controller.counts(null).get("myPending"));
        assertEquals(1L,controller.counts(null).get("myRejected"));
        assertEquals("PENDING",controller.detail((UUID)pending.get("id")).get("status"));
        fixture.loginAs(outsider);
        assertThrows(AccessDeniedException.class,()->controller.counts(null));
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
