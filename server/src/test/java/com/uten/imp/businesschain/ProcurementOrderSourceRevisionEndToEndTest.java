package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProcurementOrderSourceRevisionPort;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.*;

/** Real source generation, finance claims, quantity changes and unchanged database guards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=source-revision-jwt-test-only-01234567890123456789",
        "uten.crypto.pgp-master-key=source-revision-pgp-test-only-01234567890123456789",
        "uten.crypto.hmac-key=source-revision-hmac-test-only",
        "uten.bootstrap.admin-login=source-revision-bootstrap-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"
})
class ProcurementOrderSourceRevisionEndToEndTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        DB.start();
        registry.add("spring.datasource.url",DB::getJdbcUrl);registry.add("spring.datasource.username",DB::getUsername);
        registry.add("spring.datasource.password",DB::getPassword);
        Path uploads=Files.createTempDirectory("source-revision-uploads-");registry.add("uten.storage.local-dir",uploads::toString);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired ProcurementOrderSourceRevisionPort sources;
    @Autowired PlatformTransactionManager transactions;
    @Autowired FulfillmentMutationLocks mutationLocks;
    private FullChainEndToEndTest harness;
    @BeforeEach void harness(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @AfterAll static void stop(){DB.stop();}

    @Test void reducedOrderReturnsOnlyTwoToOriginalDemandAndLaterIncreaseAndWholeReversalAreExact(){
        Fixture f=fixture("revision-exact");UUID source=source(f.orderId());UUID transfer=transfer(f.orderId(),source);
        UUID requestPeg=jdbc.queryForObject("SELECT from_peg_id FROM production_material_peg_transfers WHERE id=?",UUID.class,transfer);
        UUID targetPeg=jdbc.queryForObject("SELECT to_peg_id FROM production_material_peg_transfers WHERE id=?",UUID.class,transfer);
        UUID demand=jdbc.queryForObject("SELECT demand_id FROM production_material_peg_transfers WHERE id=?",UUID.class,transfer);
        change(f,f.orderId(),"18");
        quantity("SELECT qty FROM purchase_request_items WHERE id=?",source,"20");
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",source,"18");
        quantity("SELECT alloc_qty FROM purchase_order_item_sources WHERE request_item_id=? AND order_item_id IN(SELECT id FROM purchase_order_items WHERE order_id='"+f.orderId()+"')",source,"18");
        quantity("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?",requestPeg,"2");
        quantity("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?",targetPeg,"18");
        quantity("SELECT required_qty FROM production_material_demands WHERE id=?",demand,"20");
        quantity("SELECT transferred_qty FROM production_material_peg_transfers WHERE id=?",transfer,"20");
        UUID revision=jdbc.queryForObject("SELECT id FROM procurement_order_source_revisions WHERE order_id=?",UUID.class,f.orderId());
        assertThatThrownBy(()->replicaWrite("UPDATE procurement_order_source_revisions SET new_qty=17 WHERE id=?",revision))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replicaWrite("UPDATE procurement_order_qty_change_logs SET new_qty=17 WHERE id=?",revision))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replicaWrite("UPDATE production_material_peg_transfers SET transferred_qty=19 WHERE id=?",transfer))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replicaWrite("UPDATE purchase_order_items SET goods_name_snapshot='replica rewrite' WHERE id=?",item(f.orderId())))
                .isInstanceOf(RuntimeException.class);
        reconfirm(f,f.orderId());change(f,f.orderId(),"20");reconfirm(f,f.orderId());
        quantity("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?",targetPeg,"20");
        quantity("SELECT fn_procurement_transfer_net_qty('PURCHASE',?)",transfer,"20");
        assertThat(jdbc.queryForList("SELECT qty_delta_base FROM procurement_order_source_revision_peg_changes WHERE transfer_id=? ORDER BY change_sequence",BigDecimal.class,transfer))
                .usingComparatorForType(BigDecimal::compareTo,BigDecimal.class).containsExactly(new BigDecimal("-2"),new BigDecimal("2"));
        assertThatThrownBy(()->change(f,f.orderId(),"21")).hasMessageContaining("剩余可订数量不足");
        harness.loginAs(f.world().superAdminUserId());orders.reverse(f.orderId());
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",source,"0");
        quantity("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?",requestPeg,"20");
        quantity("SELECT transferred_qty FROM production_material_peg_transfers WHERE id=?",transfer,"20");
        assertThat(jdbc.queryForObject("SELECT status FROM production_material_peg_transfers WHERE id=?",String.class,transfer)).isEqualTo("REVERSED");
    }

    @Test void mergedSourcesKeepFifoAndZeroAnchorsAndRestoreOnlyOriginalCapacity(){
        Fixture f=fixture("revision-merge");UUID firstSource=source(f.orderId());
        harness.loginAs(f.world().superAdminUserId());orders.reverse(f.orderId());
        var second=harness.submitPurchaseForFinance(f.world(),f.product(),f.raw(),"10");
        harness.loginAs(second.reviewerUserId());harness.approvePendingFinance("PURCHASE",second.orderId());
        UUID secondSource=source(second.orderId());harness.loginAs(f.world().superAdminUserId());orders.reverse(second.orderId());
        UUID merged=createOrder(f,List.of(firstSource,secondSource),"45");
        List<UUID> fifo=jdbc.queryForList("SELECT s.request_item_id FROM purchase_order_item_sources s JOIN purchase_order_items i ON i.id=s.order_item_id WHERE i.order_id=? ORDER BY s.line_no,s.id",UUID.class,merged);
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getFirst(),"20");
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getLast(),"25");
        change(f,merged,"10");
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getFirst(),"10");
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getLast(),"0");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM purchase_order_item_sources WHERE order_item_id=?",Integer.class,item(merged))).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT fn_purchase_order_source_share(?,?,12)",BigDecimal.class,item(merged),fifo.getLast())).isEqualByComparingTo("0");
        reconfirm(f,merged);change(f,merged,"40");reconfirm(f,merged);
        for(UUID source:fifo){quantity("SELECT qty FROM purchase_request_items WHERE id=?",source,"20");quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",source,"20");}
        assertThatThrownBy(()->change(f,merged,"41")).hasMessageContaining("剩余可订数量不足");
        quantity("SELECT qty FROM purchase_order_items WHERE id=?",item(merged),"40");
    }

    @Test void nakedQuantityCommercialOrSourceEditsFailAndUnfinishedRevisionRollsBack(){
        Fixture f=fixture("revision-guard");UUID item=item(f.orderId());
        assertThatThrownBy(()->jdbc.update("UPDATE purchase_order_items SET qty=18,amount_original=900,amount_local=900 WHERE id=?",item));
        jdbc.update("UPDATE purchase_order_items SET goods_code_snapshot=goods_code_snapshot WHERE id=?",item);
        assertThatThrownBy(()->jdbc.update("UPDATE purchase_order_items SET goods_name_snapshot='changed history' WHERE id=?",item));
        assertThatThrownBy(()->jdbc.update("UPDATE purchase_order_item_sources SET alloc_qty=18 WHERE order_item_id=?",item));
        UUID revision=UUID.randomUUID();harness.loginAs(f.world().superAdminUserId());
        AtomicBoolean applied=new AtomicBoolean();
        assertThatThrownBy(()->new TransactionTemplate(transactions).execute(status->{
            UUID requestId=jdbc.queryForObject("SELECT request_id FROM purchase_request_items WHERE id=?",UUID.class,source(f.orderId()));
            mutationLocks.acquire(()->new FulfillmentMutationLockPlan(Set.of(
                    new CommercialSource(CommercialType.PURCHASE_ORDER,f.orderId()),new CommercialSource(CommercialType.PURCHASE_REQUEST,requestId)),
                    Set.of(new InventoryDimension(f.raw(),null)),Set.of(),Set.of(),"direct-source-revision-test"));
            sources.prepare("PURCHASE",f.orderId(),List.of(new ProcurementOrderSourceRevisionPort.Line(revision,item,new BigDecimal("20"),new BigDecimal("18"),BigDecimal.ONE)));
            jdbc.update("UPDATE purchase_order_items SET qty=18,amount_original=900,amount_local=900 WHERE id=?",item);
            jdbc.update("UPDATE purchase_orders SET total_original=900,total_local=900 WHERE id=?",f.orderId());
            sources.apply("PURCHASE",f.orderId(),List.of(revision));applied.set(true);return null;
        })).isInstanceOf(RuntimeException.class);
        assertThat(applied).isTrue();
        quantity("SELECT qty FROM purchase_order_items WHERE id=?",item,"20");
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",source(f.orderId()),"20");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM procurement_order_source_revisions WHERE id=?",Integer.class,revision)).isZero();
    }

    @Test void twoOrdersCannotBothSpendTheSameReturnedRequestCapacity() throws Exception {
        Fixture f=fixture("revision-race");UUID source=source(f.orderId());harness.loginAs(f.world().superAdminUserId());orders.reverse(f.orderId());
        UUID first=createOrder(f,List.of(source),"8"),second=createOrder(f,List.of(source),"8");
        CountDownLatch changed=new CountDownLatch(1),commit=new CountDownLatch(1);AtomicInteger waiter=new AtomicInteger();
        var executor=Executors.newFixedThreadPool(2);
        try{
            Future<?> winner=executor.submit(()->new TransactionTemplate(transactions).execute(status->{change(f,first,"11");changed.countDown();await(commit);return null;}));
            assertThat(changed.await(20,TimeUnit.SECONDS)).isTrue();
            Future<?> loser=executor.submit(()->new TransactionTemplate(transactions).execute(status->{
                waiter.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));change(f,second,"11");return null;
            }));
            long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);boolean waiting=false;
            while(System.nanoTime()<until){
                if(waiter.get()>0&&Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')",Boolean.class,waiter.get()))){waiting=true;break;}
                Thread.sleep(20);
            }
            assertThat(waiting).isTrue();commit.countDown();winner.get(20,TimeUnit.SECONDS);
            assertThatThrownBy(()->loser.get(20,TimeUnit.SECONDS)).hasCauseInstanceOf(RuntimeException.class);
        }finally{commit.countDown();executor.shutdownNow();}
        quantity("SELECT ordered_qty FROM purchase_request_items WHERE id=?",source,"19");
        quantity("SELECT qty FROM purchase_order_items WHERE id=?",item(first),"11");
        quantity("SELECT qty FROM purchase_order_items WHERE id=?",item(second),"8");
    }

    private Fixture fixture(String tag){
        var world=harness.seedWorld(tag);UUID product=UUID.randomUUID(),raw=UUID.randomUUID();
        harness.insertGoods(product,"P-"+tag,"改量回归成品","自制",world.unitId(),world.unitLegacy());
        harness.insertGoods(raw,"R-"+tag,"改量回归物料","采购",world.unitId(),world.unitLegacy());harness.insertBom(product,raw,"2");
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),raw);
        var pending=harness.submitPurchaseForFinance(world,product,raw,"10");harness.loginAs(pending.reviewerUserId());harness.approvePendingFinance("PURCHASE",pending.orderId());
        harness.loginAs(world.superAdminUserId());return new Fixture(world,product,raw,pending.orderId(),pending.reviewerUserId());
    }
    private UUID createOrder(Fixture f,List<UUID> sourceIds,String qty){
        harness.loginAs(f.world().superAdminUserId());OrderSaveRequest request=new OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026,1,15));request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());
        request.setCurrencyId(f.world().currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(jdbc.queryForObject("SELECT settlement_method_id FROM purchase_orders WHERE id=?",UUID.class,f.orderId()));
        OrderItemLine line=new OrderItemLine();line.setGoodsId(f.raw());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setRequestItemId(sourceIds.getFirst());line.setRequestItemIds(sourceIds);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));
        UUID order=orders.create(request).getId();finance.submit("PURCHASE",order);harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order);return order;
    }
    private void change(Fixture f,UUID order,String qty){harness.loginAs(f.world().superAdminUserId());orders.changeQty(order,new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(item(order),new BigDecimal(qty)))));}
    private void reconfirm(Fixture f,UUID order){harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order);harness.loginAs(f.world().superAdminUserId());}
    private UUID item(UUID order){return jdbc.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? AND is_deleted=FALSE",UUID.class,order);}
    private UUID source(UUID order){return jdbc.queryForObject("SELECT request_item_id FROM purchase_order_items WHERE order_id=?",UUID.class,order);}
    private UUID transfer(UUID order,UUID source){return jdbc.queryForObject("SELECT t.id FROM production_material_peg_transfers t JOIN purchase_order_items i ON i.id=t.order_item_id WHERE i.order_id=? AND t.request_item_id=? AND t.status='EFFECTIVE'",UUID.class,order,source);}
    private void quantity(String sql,UUID id,String expected){assertThat(jdbc.queryForObject(sql,BigDecimal.class,id)).isEqualByComparingTo(expected);}
    private void replicaWrite(String sql,UUID id){new TransactionTemplate(transactions).execute(status->{jdbc.execute("SET LOCAL session_replication_role='replica'");jdbc.update(sql,id);return null;});}
    private static void await(CountDownLatch latch){try{if(!latch.await(30,TimeUnit.SECONDS))throw new IllegalStateException("barrier timeout");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new IllegalStateException(e);}}
    private record Fixture(FullChainEndToEndTest.World world,UUID product,UUID raw,UUID orderId,UUID reviewer){}
}
