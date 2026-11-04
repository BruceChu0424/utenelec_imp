package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.ret.SalesReturnService;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.*;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.test.web.servlet.MockMvc;
import com.fasterxml.jackson.databind.ObjectMapper;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.*;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;

/** Current SHIPPED documents take the real return/inspection path, never a direct reversal shortcut. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SalesReturnActualSourceQuantityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
        FullChainEndToEndTest.registerDataSource(registry);
        String location=System.getProperty("uten.shipment.test.migrations");
        if(location!=null)registry.add("spring.flyway.locations",()->"filesystem:"+location);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    @Autowired SalesReturnService returns;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void aWholeReturnAndItsUntouchedInverseRetainTheActuallyShippedAdoption()throws Exception {
        var source=ship("whole",".1","1.234567890123456789012345",false);
        String policy=db.queryForObject("SELECT quantity_precision_policy::text FROM sales_shipment_items WHERE id=?",String.class,source.item());
        assertThatThrownBy(()->shipments.reverse(source.document())).isInstanceOf(ApiException.class);
        UUID returned;
        try(var unrelated=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"HALF_UP"),
                "sales.return.base-quantity",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            returned=approve(source,".1");
        }
        equal(source.base(),quality(returned));equal(source.base(),valueMoved(returned,"SALES_RETURN_RECEIVED"));
        equal(BigDecimal.ZERO,cogs(source));
        try(var unrelated=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"DOWN")))){returns.reverse(returned);}
        equal(source.base(),valueMoved(returned,"SALES_RETURN_RECEIPT_REVERSED"));equal(source.base(),cogs(source));
        equal(BigDecimal.ZERO,db.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id=?",BigDecimal.class,source.item()));
        assertThat(db.queryForObject("SELECT quantity_precision_policy::text FROM sales_shipment_items WHERE id=?",String.class,source.item())).isEqualTo(policy);
    }

    @Test void cumulativeTargetUsesActualEarlierPiecesAndTheLastReturnOwnsEveryRemainder()throws Exception {
        var source=ship("parts",".3",".123456789012345678901234",false);
        var draft=returns.create(request(source,".1"));
        var actor=org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        var response=http.perform(post("/api/sales/returns/"+draft.getId()+"/approve").with(authenticated(actor))).andReturn().getResponse();
        assertThat(response.getStatus()).as(response.getContentAsString()).isEqualTo(422);
        var error=json.readTree(response.getContentAsString());
        assertThat(error.findValue("calculationKey").asText()).isEqualTo("sales.return.base-quantity");
        assertThat(error.findValue("notWritten").asBoolean()).isTrue();
        fixture.loginAs(source.world().superAdminUserId());
        assertThat(db.queryForObject("SELECT count(*) FROM sales_return_quality_items WHERE return_id=?",Integer.class,draft.getId())).isZero();
        equal(BigDecimal.ZERO,db.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id=?",BigDecimal.class,source.item()));
        try(var choice=BusinessPrecisionContext.use(Map.of("sales.return.base-quantity",new BusinessPrecisionContext.Choice(24,"DOWN")))){returns.approve(draft.getId());}
        UUID second;
        try(var choice=BusinessPrecisionContext.use(Map.of("sales.return.base-quantity",new BusinessPrecisionContext.Choice(24,"HALF_UP")))){second=approve(source,".1");}
        UUID last;
        try(var unrelated=BusinessPrecisionContext.use(Map.of("sales.return.base-quantity",new BusinessPrecisionContext.Choice(0,"DOWN")))){last=approve(source,".1");}
        equal(new BigDecimal(".012345678901234567890123"),quality(draft.getId()));
        equal(new BigDecimal(".012345678901234567890124"),quality(second));
        equal(new BigDecimal(".012345678901234567890123"),quality(last));
        equal(source.base(),quality(draft.getId()).add(quality(second)).add(quality(last)));equal(BigDecimal.ZERO,cogs(source));
    }

    @Test void originalMovementUsesTheActualItemWarehouseWhileQuarantineMayUseAnotherWarehouse()throws Exception {
        var source=ship("item-warehouse",".1","1.234567890123456789012345",true);
        UUID returned=approve(source,".1");
        equal(source.base(),quality(returned));equal(source.base(),valueMoved(returned,"SALES_RETURN_RECEIVED"));
        assertThat(db.queryForObject("SELECT warehouse_id FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_item_id=?",UUID.class,source.item())).isEqualTo(source.actualWarehouse());
        assertThat(db.queryForObject("SELECT warehouse_id FROM sales_return_quality_items WHERE return_id=?",UUID.class,returned)).isEqualTo(source.world().warehouseId());
        assertThat(source.actualWarehouse()).isNotEqualTo(source.world().warehouseId());
    }

    private Source ship(String label,String qty,String rate,boolean anotherWarehouse)throws Exception {
        var w=fixture.seedWorld("return-source-"+label+"-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());
        UUID warehouse=anotherWarehouse?call("leafWarehouse","return-source-"+UUID.randomUUID()):w.warehouseId();
        call("putDirectTargetStockZeroPriceAt",w,w.goodsB(),BigDecimal.ONE,warehouse);
        UUID unit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name) VALUES(?,?,'box')",unit,"RETURN-NATIVE-"+unit);
        ShipmentSaveRequest request=call("directCustomerShipmentRequest",w,"FREE",qty);
        var line=request.getItems().getFirst();line.setUnitId(unit);line.setUnitRate(new BigDecimal(rate));
        ShipmentDetail draft;
        try(var choice=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(24,"DOWN")))){draft=shipments.create(request);}
        UUID item=draft.getItems().getFirst().getId();shipments.confirmSales(draft.getId(),0L);call("confirmShipmentFinance",draft.getId());
        var transition=new WarehouseWorkTransitionRequest();transition.setTargetStatus("SHIPPED");transition.setWarehouseId(w.warehouseId());
        transition.setStockPlaces(List.of(new WarehouseWorkTransitionRequest.StockPlace(item,"",warehouse,null)));
        shipments.transitionWarehouseWork(draft.getId(),transition);
        BigDecimal base=db.queryForObject("SELECT qty FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_item_id=?",BigDecimal.class,item);
        return new Source(w,draft.getId(),item,unit,new BigDecimal(rate),base,warehouse);
    }
    private ReturnSaveRequest request(Source source,String qty){
        ReturnSaveRequest request=call("directReturnRequest",source.world(),shipments.detail(source.document()),qty);
        request.getItems().getFirst().setUnitId(source.unit());request.getItems().getFirst().setUnitRate(source.rate());return request;
    }
    private UUID approve(Source source,String qty){UUID id=returns.create(request(source,qty)).getId();returns.approve(id);return id;}
    private BigDecimal quality(UUID id){return db.queryForObject("SELECT received_base_qty FROM sales_return_quality_items WHERE return_id=?",BigDecimal.class,id);}
    private BigDecimal valueMoved(UUID id,String kind){return db.queryForObject("SELECT COALESCE(sum(qty_base),0) FROM stock_value_events WHERE source_doc_type=? AND source_doc_id=? AND operation='POSITION_MOVE'",BigDecimal.class,kind,id);}
    private BigDecimal cogs(Source source){return db.queryForObject("""
        SELECT COALESCE(sum(head.range_to-head.range_from),0) FROM stock_value_nodes root
        JOIN stock_value_nodes head ON head.id=root.return_head_id
        WHERE root.id=root.root_issue_id AND root.kind='ISSUE_POSITION' AND root.owner_kind='COGS' AND root.owner_id=?
          AND head.owner_kind='COGS' AND head.owner_id=? AND head.active
        """,BigDecimal.class,source.item(),source.item());}
    private static void equal(BigDecimal expected,BigDecimal actual){assertThat(actual).isEqualByComparingTo(expected);}
    @SuppressWarnings("unchecked") private <T>T call(String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(fixture,method,args);}
    private record Source(FullChainEndToEndTest.World world,UUID document,UUID item,UUID unit,BigDecimal rate,BigDecimal base,UUID actualWarehouse){}
}
