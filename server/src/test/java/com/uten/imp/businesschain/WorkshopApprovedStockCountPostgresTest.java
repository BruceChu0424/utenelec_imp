package com.uten.imp.businesschain;

import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPeriodService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.count.StockCountDtos;
import com.uten.imp.features.stock.count.StockCountRequestController;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.*;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.workshop-material.auto-close.enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopApprovedStockCountPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars tx;
    @Autowired DocNumberService numbers;
    @Autowired WorkshopStockCountPostingPort posting;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialPeriodService periods;
    @Autowired WorkshopMaterialCountService counts;
    @Autowired WorkshopMaterialRequisitionService requisitions;
    @Autowired StockDocService stockDocuments;
    @Autowired StockCountRequestController stockCountRequests;
    FullChainEndToEndTest fixture;
    record Shop(FullChainEndToEndTest.World world,UUID workshop,UUID unit,UUID goods,UUID bin,UUID period) {}
    record Request(UUID id,UUID line,UUID event) {}
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    /**
     * 用户 2026-10-04 的原路径: 内料仓页「库存盘点」不填说明直接「保存并送审」(V766 约束曾回 409),
     * 送审不动库存 -> 仓库审核 -> 两种颗粒各记一行上线期初; 同一提交编号与同一审核命令重放都只生效一次。
     */
    @Test void blankExplanationWorkshopCountIsSubmittedThenWarehouseApprovedAsOpeningOnce() {
        Shop shop=shop(false);
        UUID secondGoods=UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,issue_method,periodic_cost_basis,min_qty)
                SELECT ?,?,'另一种期初颗粒',source_type,status,unit_id,unit_legacy_id,price,
                       (SELECT coalesce(max(code_sequence),0)+1 FROM goods),issue_method,periodic_cost_basis,min_qty
                FROM goods WHERE id=?
                """,secondGoods,"COUNT2-"+secondGoods.toString().substring(0,8),shop.goods());
        java.util.function.Function<UUID,Long> version=goods->((Number)stockCountRequests.candidates(shop.bin(),"",List.of(goods),1,50)
                .getItems().getFirst().get("goodsVersion")).longValue();
        var first=new StockCountDtos.LineInput(shop.goods(),null,shop.unit(),BigDecimal.ZERO,null,false,
                new BigDecimal("1000"),new BigDecimal("1000"),true,null,version.apply(shop.goods()));
        var second=new StockCountDtos.LineInput(secondGoods,null,shop.unit(),BigDecimal.ZERO,null,false,
                new BigDecimal("1111"),new BigDecimal("1111"),true,null,version.apply(secondGoods));
        var proposal=new StockCountDtos.Submit(shop.bin(),"",key(),List.of(first,second));
        var request=stockCountRequests.submit(proposal);
        UUID id=(UUID)request.get("id");
        assertEquals("WAREHOUSE",request.get("reviewRoute"));
        assertEquals("PENDING",request.get("status"));
        assertEquals("",db.queryForObject("SELECT reason FROM stock_count_requests WHERE id=?",String.class,id));
        equal("0",qty(shop));
        assertEquals(id,stockCountRequests.submit(new StockCountDtos.Submit(shop.bin(),null,proposal.idempotencyKey(),proposal.lines())).get("id"),
                "不传说明与空说明是同一次提交");
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_count_request_events WHERE request_id=? AND action='SUBMIT'",Integer.class,id));
        var decision=new StockCountDtos.Decision(0L,key(),null);
        assertEquals("APPROVED",stockCountRequests.approve(id,decision).get("status"));
        assertEquals("APPROVED",stockCountRequests.approve(id,decision).get("status"));
        equal("1000",qty(shop));
        equal("1111",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class,shop.bin(),secondGoods));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings WHERE request_id=? AND kind='OPENING'",
                Integer.class,id));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_count_request_events WHERE request_id=? AND action='APPROVE'",Integer.class,id));
    }

    @Test void firstInventoryApprovalWithdrawsAnUntouchedCycleCountInTheSameTransaction() {
        Shop shop=shop(false);
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_count_lines WHERE count_id=?",Integer.class,started.count().id()));
        Request initial=request(shop,"0",null,"100","100",null);
        approve(shop,initial);
        equal("100",qty(shop));
        assertEquals("OPENING",kind(initial));
        assertEquals("OPEN",periodStatus(shop.period()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_periods WHERE bin_warehouse_id=?",Integer.class,shop.bin()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_counts WHERE id=?",Integer.class,started.count().id()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_commands WHERE command_kind='COUNT_WITHDRAW' AND idempotency_key=?",
                Integer.class,"COUNT-APPROVAL-RECOVER:"+initial.event()),"正式撤回命令留下审核人、请求键和结果证据");
        assertEquals(shop.period(),db.queryForObject("SELECT period_id FROM workshop_material_count_adjustment_postings WHERE line_id=?",UUID.class,initial.line()));
    }

    @Test void untouchedCountStillRecoversTheInitialPeriodAfterTheBusinessDateRollsOver() {
        Shop shop=shop(false,BusinessTime.today().minusDays(1));
        periods.startCount(shop.period(),new StartCountRequest(0L,BusinessTime.today().minusDays(1),key()));
        Request initial=request(shop,"0",null,"100","100",null);
        approve(shop,initial);
        assertEquals("OPENING",kind(initial),"过了截止日也不能把未录入的上线期初误记为第二期账面修正");
        assertEquals(shop.period(),db.queryForObject("SELECT period_id FROM workshop_material_count_adjustment_postings WHERE line_id=?",UUID.class,initial.line()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_periods WHERE bin_warehouse_id=?",Integer.class,shop.bin()));
        equal("100",qty(shop));
    }

    @Test void recordedCycleCountCannotBeDiscardedByInventoryApproval() {
        Shop shop=shop(false);
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        counts.saveLine(started.count().id(),"actual-record",new CountLineInput(null,"WEIGHED","LOOSE",shop.goods(),null,
                null,null,new BigDecimal("5"),null,null,null));
        Request initial=request(shop,"0",null,"100","100",null);
        assertTrue(assertThrows(ApiException.class,()->approve(shop,initial)).getMessage().contains("已有盘点录入"));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,initial.id()));
        assertEquals("COUNTING",periodStatus(shop.period()));
        equal("0",qty(shop));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_count_lines WHERE count_id=?",Integer.class,started.count().id()));
        // 用户明确选择撤回旧周期盘点后, 仍可用原库存申请继续审核。
        periods.withdrawCount(shop.period(),new VersionRequest(started.period().rowVersion(),key()));
        approve(shop,initial);
        equal("100",qty(shop));
    }

    @Test void failedInventoryApprovalRollsBackTheAutomaticWithdrawalToo() {
        Shop shop=shop(false);
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        Request invalid=request(shop,"0",null,"10","10000",null);
        assertThrows(ApiException.class,()->approve(shop,invalid));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,invalid.id()));
        assertEquals("COUNTING",periodStatus(shop.period()));
        assertEquals("OPEN",periodStatus(started.nextPeriod().id()));
        assertEquals("DRAFT",db.queryForObject("SELECT status FROM workshop_material_counts WHERE id=?",String.class,started.count().id()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_commands WHERE idempotency_key=?",Integer.class,
                "COUNT-APPROVAL-RECOVER:"+invalid.event()));
        equal("0",qty(shop));
    }

    @Test void successorReceiptsPreventAutomaticAndManualWithdrawal() {
        Shop shop=shop(false);
        var item=new StockDocItemLine(); item.setGoodsId(shop.goods());item.setUnitId(shop.unit());item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("100"));item.setPrice(BigDecimal.TEN);item.setAmountLocal(new BigDecimal("1000"));item.setAmountOriginal(new BigDecimal("1000"));
        var incoming=new StockDocSaveRequest();incoming.setDocType("OTHER_IN");incoming.setWarehouseId(shop.world().warehouseId());
        incoming.setBillDate(BusinessTime.today());incoming.setItems(List.of(item));stockDocuments.approve(stockDocuments.create(incoming).getId());
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        Request initial=request(shop,"0",null,"100","100",null);
        requisitions.directIssue(new DirectIssueRequest(shop.workshop(),shop.world().employeeId(),
                List.of(new DirectIssueLine(shop.goods(),null,null,BigDecimal.TEN,shop.world().warehouseId())),null,key()));
        assertTrue(assertThrows(ApiException.class,()->approve(shop,initial)).getMessage().contains("下一期已有"));
        assertThrows(ApiException.class,()->periods.withdrawCount(shop.period(),new VersionRequest(started.period().rowVersion(),key())));
        assertEquals("COUNTING",periodStatus(shop.period()));
        equal("10",qty(shop));
    }

    @Test void approvedOpeningAndLaterAdjustmentAreNotIssuedOrConsumedAgain() {
        Shop shop=shop(false);
        Request first=request(shop,"0",null,"100","100",null);
        assertEquals(0,qty(shop).signum(),"送审不动库存");
        assertThrows(ApiException.class,()->new TransactionTemplate(transactions).execute(s->posting.postApproved(first.id(),first.event())));
        var receipt=approve(shop,first);
        assertEquals(1,receipt.lines().size());
        equal("100",qty(shop));
        assertEquals("OPENING",kind(first));
        assertEquals("PENDING",db.queryForObject("SELECT result_state FROM stock_value_events WHERE source_doc_type='STOCK_COUNT_REQUEST' AND source_doc_id=? AND operation='RECEIVE'",
                String.class,first.id()),"期初没有价格不得核零成本");
        assertEquals(receipt,new TransactionTemplate(transactions).execute(s->posting.postApproved(first.id(),first.event())));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings WHERE request_id=?",Integer.class,first.id()));
        Request lower=request(shop,"100","100","80","80",null);
        approve(shop,lower);
        assertEquals("ADJUSTMENT",kind(lower));
        equal("80",qty(shop));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_requisitions WHERE bin_warehouse_id=?",Integer.class,shop.bin()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_movements WHERE warehouse_id=? AND movement_type=21",Integer.class,shop.bin()));
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        counts.saveLine(started.count().id(),"approved-opening-physical",new CountLineInput(null,"WEIGHED","LOOSE",
                shop.goods(),null,null,null,new BigDecimal("80"),null,null,null));
        counts.submit(started.count().id(),new VersionRequest(started.count().rowVersion(),key()));
        var periodLine=db.queryForMap("SELECT opening_qty,adjustment_qty,closing_qty,actual_qty FROM workshop_material_period_lines WHERE period_id=? AND goods_id=?",
                shop.period(),shop.goods());
        equal("100",(BigDecimal)periodLine.get("opening_qty"));
        equal("-20",(BigDecimal)periodLine.get("adjustment_qty"));
        equal("80",(BigDecimal)periodLine.get("closing_qty"));
        equal("0",(BigDecimal)periodLine.get("actual_qty"));
        equal("80",qty(shop));
    }

    @Test void staleApprovalRollsBackItsDecisionAndNeverOverwritesInventory() {
        Shop shop=shop(false);
        Request stale=request(shop,"0",null,"30","30",null);
        Request current=request(shop,"0",null,"20","20",null);
        approve(shop,current);
        assertThrows(ApiException.class,()->approve(shop,stale));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,stale.id()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings WHERE request_id=?",Integer.class,stale.id()));
        equal("20",qty(shop));
        assertThrows(ApiException.class,()->new TransactionTemplate(transactions).execute(s->posting.postApproved(current.id(),UUID.randomUUID())));
        Request unitChanged=request(shop,"20","20","30","30",null);
        db.update("UPDATE unit_measurement_profiles SET mass_unit_code='G' WHERE unit_id=?",shop.unit());
        assertTrue(assertThrows(ApiException.class,()->approve(shop,unitChanged)).getMessage().contains("重量换算已变化"));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,unitChanged.id()));
        equal("20",qty(shop));
    }

    @Test void firstOrderMaterialUsesExplicitSetupAndRejectsConflictingWeight() {
        Shop shop=shop(true);
        Request missing=request(shop,"0",null,"10","10",null);
        assertTrue(assertThrows(ApiException.class,()->approve(shop,missing)).getMessage().contains("确认材料用途"));
        assertEquals("ORDER",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()));
        Request mismatched=request(shop,"0",null,"10","10000","OWN");
        assertThrows(ApiException.class,()->approve(shop,mismatched));
        assertEquals("ORDER",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()),"重量错误使首次设置一并回滚");
        Request correct=request(shop,"0",null,"10","10","OWN");
        approve(shop,correct);
        equal("10",qty(shop));
        assertEquals("PERIODIC",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()));
    }

    @Test void bulkWarehouseVisibilityMatchesSingleChecksForRestrictedAndAdminActors() {
        Shop own=shop(false), other=shop(false);
        fixture.loginAs(own.world().superAdminUserId());
        UUID member=fixture.createUserWithPerms(own.world(),"scope-"+UUID.randomUUID(),"stock:count:warehouse_review");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",own.workshop(),member);
        var ids=List.of(own.bin(),other.bin(),own.world().warehouseId(),UUID.randomUUID());
        fixture.loginAs(member);
        assertTrue(posting.canAccessWarehouse(own.bin()));
        assertFalse(posting.canAccessWarehouse(other.bin()));
        assertEquals(java.util.Set.of(own.bin()),posting.accessibleWarehouses(ids));
        fixture.loginAs(own.world().superAdminUserId());
        long version=db.queryForObject("SELECT row_version FROM workshop_bins WHERE workshop_department_id=?",Long.class,own.workshop());
        settings.update(own.workshop(),new SettingsRequest("OPEN_PERIODIC",version,false,null, null,null,null,List.of(),key()));
        for (UUID actor:List.of(member,own.world().superAdminUserId())) {
            fixture.loginAs(actor);
            assertEquals(ids.stream().filter(posting::canAccessWarehouse).collect(java.util.stream.Collectors.toSet()),posting.accessibleWarehouses(ids));
        }
        assertEquals(java.util.Set.of(),posting.accessibleWarehouses(List.of()));
    }

    private Shop shop(boolean order) {
        return shop(order,BusinessTime.today());
    }

    private Shop shop(boolean order,LocalDate goLive) {
        fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
        String tag="approved-count-"+UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld(tag); fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID();
        int legacy=800_000_000+ThreadLocalRandom.current().nextInt(50_000_000);
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",unit,legacy,"KG-"+tag);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES (?,'MASS','KG','MANUAL_GOVERNANCE')",unit);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,issue_method,periodic_cost_basis,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),?,?,0)
                """,goods,"COUNT-"+tag,"期初颗粒",unit,legacy,order?"ORDER":"PERIODIC",order?null:"OWN");
        var enabled=settings.update(workshop,new SettingsRequest("NOT_OPEN",0L,true,world.warehouseId(), null,true,goLive,List.of(),key()));
        return new Shop(world,workshop,unit,goods,enabled.binWarehouseId(),enabled.currentPeriod().id());
    }

    private Request request(Shop shop,String expected,String expectedWeight,String target,String targetWeight,String basis) {
        return new TransactionTemplate(transactions).execute(status->{
            tx.bind(); UUID request=UUID.randomUUID(),line=UUID.randomUUID(),event=UUID.randomUUID();
            db.update("""
                    INSERT INTO stock_count_requests(id,request_no,warehouse_id,review_route,submitted_by,reason,command_key,request_hash)
                    VALUES (?,?,?,'WAREHOUSE',?,'核对现存实物',?,'test')
                    """,request,numbers.nextNumber(DocNumberPrefix.STOCK_COUNT_REQUEST),shop.bin(),shop.world().superAdminUserId(),key());
            db.update("""
                    INSERT INTO stock_count_request_lines(id,request_id,line_no,goods_id,unit_id,expected_qty,expected_weight_kg,
                        expected_weight_estimated,target_qty,target_weight_kg,weight_changed,material_setup_basis,goods_version,
                        goods_name,unit_name,kg_per_base_unit)
                    VALUES (?,?,1,?,?,?,?,FALSE,?,?,TRUE,?,(SELECT version FROM goods WHERE id=?),'颗粒','千克',1)
                    """,line,request,shop.goods(),shop.unit(),new BigDecimal(expected),expectedWeight==null?null:new BigDecimal(expectedWeight),
                    new BigDecimal(target),new BigDecimal(targetWeight),basis,shop.goods());
            return new Request(request,line,event);
        });
    }

    private WorkshopStockCountPostingPort.PostingResult approve(Shop shop,Request request) {
        return new TransactionTemplate(transactions).execute(status->{
            tx.bind();
            db.update("INSERT INTO stock_count_request_events(id,request_id,action,actor_id,request_version,command_key) VALUES (?,?,'APPROVE',?,1,?)",
                    request.event(),request.id(),shop.world().superAdminUserId(),key());
            db.update("UPDATE stock_count_requests SET status='APPROVED',row_version=1,approval_event_id=?,reviewed_by=?,reviewed_at=now() WHERE id=?",
                    request.event(),shop.world().superAdminUserId(),request.id());
            return posting.postApproved(request.id(),request.event());
        });
    }
    private BigDecimal qty(Shop shop) { return db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,shop.bin(),shop.goods()); }
    private String periodStatus(UUID period) { return db.queryForObject("SELECT status FROM workshop_material_periods WHERE id=?",String.class,period); }
    private String kind(Request request) { return db.queryForObject("SELECT kind FROM workshop_material_count_adjustment_postings WHERE line_id=?",String.class,request.line()); }
    private static String key() { return "approved-count-"+UUID.randomUUID(); }
    private static void equal(String expected,BigDecimal actual) { assertNotNull(actual); assertEquals(0,new BigDecimal(expected).compareTo(actual)); }
}
