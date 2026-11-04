package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ShipmentExactQuantityPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
        FullChainEndToEndTest.registerDataSource(registry);
        String location=System.getProperty("uten.shipment.test.migrations");
        if(location!=null)registry.add("spring.flyway.locations",()->"filesystem:"+location);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void tinyPhysicalQuantityAndMeasuredWeightChoiceCommitOnlyOnce() throws Exception {
        var w=fixture.seedWorld("ship-native-tiny");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsB(),"1");
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"directCustomerShipmentRequest",w,"FREE","0.000000000000000000000001");
        var declared=new BigDecimal("0.000000000000000000000001");request.getItems().getFirst().setWeight(declared);
        var draft=shipments.create(request);UUID item=draft.getItems().getFirst().getId();
        equal("0.000000000000000000000001",db.queryForObject("SELECT adopted_base_qty FROM sales_shipment_items WHERE id=?",BigDecimal.class,item));
        equal(declared.toPlainString(),db.queryForObject("SELECT weight FROM sales_shipment_items WHERE id=?",BigDecimal.class,item));
        shipments.confirmSales(draft.getId(),0L);ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",draft.getId());
        var transition=transition(w.warehouseId(),item,new BigDecimal("0.1234567890123456789012345"));
        assertThrows(BusinessPrecisionRequiredException.class,()->shipments.transitionWarehouseWork(draft.getId(),transition));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_reservations WHERE source_doc_id=?",Integer.class,draft.getId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM sales_shipment_warehouse_events WHERE shipment_id=? AND to_status='SHIPPED'",Integer.class,draft.getId()));
        try(var ignored=BusinessPrecisionContext.use(Map.of("weight.kg-field",new BusinessPrecisionContext.Choice(24,"DOWN")))){
            shipments.transitionWarehouseWork(draft.getId(),transition);
        }
        equal("0.000000000000000000000001",db.queryForObject("SELECT qty FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
        equal("0.000000000000000000000001",db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE source_doc_id=?",BigDecimal.class,draft.getId()));
        assertEquals("0.1234567890123456789012345",db.queryForObject("SELECT original_decimal FROM business_numeric_input_evidence WHERE owner_kind='SALES_SHIPMENT' AND owner_id=? AND source_row_id=? AND field_key='warehouseMeasuredWeightKg'",String.class,draft.getId(),item));
        assertEquals("0.123456789012345678901234",db.queryForObject("SELECT recorded_decimal FROM business_numeric_input_evidence WHERE owner_kind='SALES_SHIPMENT' AND owner_id=? AND source_row_id=? AND field_key='warehouseMeasuredWeightKg'",String.class,draft.getId(),item));
        assertThrows(ApiException.class,()->shipments.transitionWarehouseWork(draft.getId(),transition));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",Integer.class,draft.getId()));
        // Current shipped documents still use actual sales return + receiving inspection.
        assertThrows(ApiException.class,()->shipments.reverse(draft.getId()));
    }

    @Test void alternateNativeUnitAdoptionRemainsFrozenWhenLaterHeaderChanges() throws Exception {
        var w=fixture.seedWorld("ship-native-rate");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsB(),"1");
        UUID box=UUID.randomUUID();db.update("INSERT INTO units(id,code,name) VALUES(?,?,'box')",box,"SHIP-NATIVE-"+box);
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"directCustomerShipmentRequest",w,"FREE","0.1");
        var line=request.getItems().getFirst();line.setUnitId(box);line.setUnitRate(new BigDecimal("1.234567890123456789012345"));
        assertThrows(BusinessPrecisionRequiredException.class,()->shipments.create(request));
        com.uten.imp.features.sales.shipment.dto.ShipmentDetail draft;
        try(var ignored=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(24,"DOWN")))){
            draft=shipments.create(request);
        }
        UUID item=draft.getItems().getFirst().getId();String originalPolicy=db.queryForObject("SELECT quantity_precision_policy::text FROM sales_shipment_items WHERE id=?",String.class,item);
        equal("0.123456789012345678901234",db.queryForObject("SELECT adopted_base_qty FROM sales_shipment_items WHERE id=?",BigDecimal.class,item));
        shipments.confirmSales(draft.getId(),0L);ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",draft.getId());
        try(var ignored=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            shipments.transitionWarehouseWork(draft.getId(),transition(w.warehouseId(),item,null));
        }
        equal("0.123456789012345678901234",db.queryForObject("SELECT qty FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
        assertEquals(originalPolicy,db.queryForObject("SELECT quantity_precision_policy::text FROM sales_shipment_items WHERE id=?",String.class,item));
        line.setUnitRate(new BigDecimal("1.2345678901234567890123456"));assertThrows(ApiException.class,()->shipments.create(request));
        line.setUnitRate(null);assertThrows(ApiException.class,()->shipments.create(request));
    }

    private static WarehouseWorkTransitionRequest transition(UUID warehouse,UUID item,BigDecimal measured){
        var request=new WarehouseWorkTransitionRequest();request.setTargetStatus("SHIPPED");request.setWarehouseId(warehouse);
        request.setStockPlaces(List.of(new WarehouseWorkTransitionRequest.StockPlace(item,"",warehouse,measured)));return request;
    }
    private static void equal(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
