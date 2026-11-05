package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

/** A real approved ordinary reservation cannot survive a reviewed switch to component delivery. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryRevisionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesOrderFinanceConfirmService finance;
    @Autowired SalesShipmentService shipments;
    @Autowired BomDeliveryService boms;
    @Autowired TaskClaimService claims;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void reviewedOrdinaryToBomRevisionReleasesOriginalStockAndShipsOnlyTheNewPhysicalFrontier() {
        String tag="delivery-revise-"+UUID.randomUUID().toString().substring(0,7);
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        support.stock(w,w.goodsA(),"5");support.stock(w,w.goodsB(),"10");support.stock(w,w.goodsE(),"5");
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");
        var created=orders.create(request);UUID order=created.getId(),item=created.getItems().getFirst().getId();
        orders.approve(order);fixture.confirmInitialSalesFinance(order);
        long originalReview=db.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,order);
        UUID originalReservation=db.queryForObject("""
                SELECT id FROM stock_reservations WHERE order_item_id=? AND owner_type='SALES_ORDER_ITEM'
                  AND status=0 AND NOT is_deleted
                """,UUID.class,item);
        assertThat(db.queryForObject("SELECT qty-consumed_qty-released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,originalReservation)).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("5");
        var originalSnapshot=finance.review(order);
        assertThat(originalSnapshot.items()).singleElement().satisfies(line->assertThat(line.deliveryPlan().mode()).isEqualTo(DeliveryPlan.Mode.ASSEMBLED));

        var tree=boms.snapshot(w.goodsA());
        var bom=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),tree.bomFingerprint());
        request.getItems().getFirst().setId(item);request.getItems().getFirst().setDeliveryPlan(bom);
        var revised=orders.update(order,request);
        assertThat(revised.getStatus()).isEqualTo((short)1);
        assertThat(revised.isFinanceConfirmed()).isFalse();assertThat(revised.getManagerReview().pending()).isTrue();
        assertThat(revised.getItems()).singleElement().satisfies(line->{assertThat(line.getId()).isEqualTo(item);assertThat(line.getDeliveryPlan()).isEqualTo(bom);});
        assertReleasedOriginal(item,originalReservation);
        assertThat(db.queryForObject("SELECT delivery_bom_snapshot->>'bomFingerprint' FROM sales_order_items WHERE id=?",String.class,item)).isEqualTo(tree.bomFingerprint());
        assertThat(db.queryForObject("SELECT count(*) FROM production_material_analysis_items WHERE sales_order_item_id=?",Integer.class,item)).isZero();

        long currentReview=fixture.approveSalesManagerReview(order,originalReview+1);
        var review=finance.review(order);
        assertThat(review.financeReviewRevision()).isEqualTo(currentReview);
        assertThat(review.items()).singleElement().satisfies(line->assertThat(line.deliveryPlan()).isEqualTo(bom));
        assertThat(review.revisionDiff()).isNotNull();
        assertThat(review.revisionDiff().changedItemIds()).containsExactly(item.toString());
        assertThat(review.revisionDiff().beforeItems()).singleElement().satisfies(line->assertThat(line.deliveryPlan().path("mode").asText()).isEqualTo("ASSEMBLED"));
        assertThat(review.revisionDiff().afterItems()).singleElement().satisfies(line->assertThat(line.deliveryPlan().path("mode").asText()).isEqualTo("BOM"));
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
        assertThatThrownBy(()->finance.confirm(order,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,originalReview,claim.claimId())))
                .isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT finance_confirmed FROM sales_orders WHERE id=?",Boolean.class,order)).isFalse();
        finance.confirm(order,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,currentReview,claim.claimId()));
        assertThat(finance.review(order).financeConfirmed()).isTrue();
        assertThat(finance.review(order).revisionDiff()).isNull();
        assertReleasedOriginal(item,originalReservation);

        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var physical=support.physical(shipment);
        assertThat(physical).hasSize(2);
        assertThat(physical).noneMatch(line->line.goodsId().equals(w.goodsA()));
        assertThat(physical).filteredOn(line->line.goodsId().equals(w.goodsB())).singleElement().satisfies(line->assertThat(line.quantity()).isEqualByComparingTo("10"));
        assertThat(physical).filteredOn(line->line.goodsId().equals(w.goodsE())).singleElement().satisfies(line->assertThat(line.quantity()).isEqualByComparingTo("5"));
        shipments.transitionWarehouseWork(shipment,support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment)));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isEqualByComparingTo("5");
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND goods_id=?",Integer.class,shipment,w.goodsA())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("5");
        assertReleasedOriginal(item,originalReservation);
    }
    private void assertReleasedOriginal(UUID item,UUID originalReservation) {
        assertThat(db.queryForObject("SELECT qty FROM stock_reservations WHERE id=?",BigDecimal.class,originalReservation)).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,originalReservation)).isZero();
        assertThat(db.queryForObject("SELECT released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,originalReservation)).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_reservations WHERE order_item_id=? AND status=0 AND NOT is_deleted AND qty-consumed_qty-released_qty>0",Integer.class,item)).isZero();
    }
}
