package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.execution.DeliveryProcessingContracts;
import com.uten.imp.features.production.execution.DeliveryProcessingService;
import com.uten.imp.features.sales.shipment.SalesShipmentDeliveryService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundProjectionService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.math.BigDecimal;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

/** Actual warehouse/worker permission sets; no sales editor or arbitrary goods picker grants. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryWarehouseScopeEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    @Autowired WarehouseSalesOutboundProjectionService warehouse;
    @Autowired DeliveryProcessingService processing;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void actualWarehouseAndAssignedWorkerCanFinishWithoutSalesOrGoodsPickerAndRevokedWritesStayBlocked(){
        var ready=support.ready("delivery-scope-","10","5",true);var w=ready.world();
        UUID workshop=UUID.randomUUID();
        UUID productionDepartment=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD' AND NOT is_deleted",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"DLV-WS-"+workshop,"最小授权加工车间",productionDepartment);
        String tag=UUID.randomUUID().toString().substring(0,7);
        UUID keeper=fixture.createUserWithPerms(w,"delivery-keeper-"+tag,"warehouse_sales_outbound:view","warehouse_sales_outbound:execute");
        UUID worker=fixture.createUserWithPerms(w,"delivery-worker-"+tag,"production_execution:view","production_execution:start","production_daily_report:create");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,worker);
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,employee);
        var component=support.physical(ready.shipment()).stream().filter(c->c.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        var assigned=processing.assign(component.id(),new DeliveryProcessingContracts.Assignment(component.revision(),workshop,employee,UUID.randomUUID()));
        fixture.loginAs(worker);
        assertThatThrownBy(()->processing.start(component.id(),new DeliveryProcessingContracts.Start(assigned.version(),w.warehouseId(),UUID.randomUUID())))
                .isInstanceOf(ApiException.class).hasMessageContaining("仓库");
        fixture.loginAs(keeper);
        assertThat(warehouse.detail(ready.shipment()).deliveryComponents()).hasSize(2);
        UUID issueId=UUID.randomUUID();
        var issue=new SalesShipmentDeliveryService.ProcessingWarehouseAction(assigned.version(),w.warehouseId(),"最小授权原仓",issueId,"实际交接10个组件至指定车间");
        var issued=shipments.processingWarehouseWork(ready.shipment(),component.id(),"ISSUE",issue);
        assertThat(shipments.processingWarehouseWork(ready.shipment(),component.id(),"ISSUE",issue).revision()).isEqualTo(issued.revision());
        assertThat(shipments.deliveryWarehouseRequestOutcome(ready.shipment(),issueId).get("found")).isEqualTo(true);
        assertThat(shipments.deliveryWarehouseRequestOutcome(ready.shipment(),UUID.randomUUID()).get("found")).isEqualTo(false);
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='warehouse_sales_outbound:execute')",keeper);
        fixture.loginAs(keeper);
        assertThatThrownBy(()->shipments.processingWarehouseWork(ready.shipment(),component.id(),"CANCEL_ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(issued.revision(),w.warehouseId(),"最小授权原仓",UUID.randomUUID(),"无办理权限不能取消")))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThat(shipments.deliveryWarehouseRequestOutcome(ready.shipment(),issueId).get("found")).isEqualTo(true);
        fixture.loginAs(worker);
        var started=processing.start(component.id(),new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        UUID reportId=UUID.randomUUID();
        var report=new DeliveryProcessingContracts.Report(started.version(),BigDecimal.TEN,"LASER","10个组件均已完成实际激光和检验",reportId);
        var completed=processing.report(component.id(),report);
        assertThat(processing.report(component.id(),report).version()).isEqualTo(completed.version());
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_processing_events WHERE request_id=?",Integer.class,reportId)).isEqualTo(1);
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code='warehouse_sales_outbound:execute'",keeper);
        fixture.loginAs(keeper);
        shipments.processingWarehouseWork(ready.shipment(),component.id(),"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                completed.version(),w.warehouseId(),"最小授权收回",UUID.randomUUID(),"按原实物收回10个加工组件"));
        warehouse.transition(ready.shipment(),support.pick(ready));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,ready.orderItem())).isEqualByComparingTo("5");
    }
}
