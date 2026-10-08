package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateInheritedRouteRefreshEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    private AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @ParameterizedTest @ValueSource(strings={"BUY","MAKE"})
    void inheritedChildSupplyKeepsCanonicalRouteWhenOriginalOrdersPrecedeParentMerge(String route){
        var c=h.create(true,false,"100",true,3,"1");
        h.setRoute(c,c.child(),"SUBCONTRACT");
        if("MAKE".equals(route))h.setRoute(c,c.material(),route);
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),route,"400",true))));
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","300",false)))).batches().getFirst();
        AnalysisView merged=h.analyses.detail(c.analysis());
        MaterialView canonical=merged.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.anchorAnalysisItemId())&&row.goodsId().equals(c.material())).findFirst().orElseThrow();
        assertTrue(canonical.downstreamReferences().isEmpty());
        assertNull(canonical.planAnchorAnalysisLineId());
        amount("300",canonical.requiredQty());amount("0",canonical.planningUncoveredQty());
        String contrary="MAKE".equals(route)?"BUY":"MAKE";
        String masterBefore=h.db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,c.material());
        var rejected=assertThrows(com.uten.imp.common.web.ApiException.class,()->h.analyses.saveRoutes(c.analysis(),new RouteRequest(merged.version(),merged.fingerprint(),"inherited-manual-route-"+UUID.randomUUID(),
                List.of(new RouteDecision(canonical.materialLineId(),canonical.actionGroupKey(),contrary,null)))));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,rejected.getCode());
        assertEquals(masterBefore,h.db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,c.material()),"Rejected inherited-route edits must not rewrite the goods master");
        h.db.update("UPDATE goods SET source_type=? WHERE id=?","MAKE".equals(route)?"采购":"自制",c.material());
        UUID edge=h.db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",UUID.class,c.child(),c.material());
        var edit=new com.uten.imp.features.master.goods.dto.BomItemSaveRequest();edit.setComponentGoodsId(c.material());edit.setControlStage("ASSEMBLY");
        beans.getBean(com.uten.imp.features.master.goods.GoodsBomService.class).update(c.child(),edge,edit);
        AnalysisView current=h.analyses.detail(c.analysis());
        List<PreviewItem> sources=current.products().stream().filter(row->row.salesOrderItemId()!=null)
                .map(row->new PreviewItem("SALES_ORDER_ITEM",row.salesOrderItemId(),null,null,null,null,null,row.deliveryDate(),row.requestedQty())).toList();
        AnalysisView refreshed=h.analyses.preview(new PreviewRequest(c.analysis(),current.version(),current.fingerprint(),c.world().warehouseId(),"inherited-route-refresh-"+UUID.randomUUID(),sources));
        MaterialView after=refreshed.flatMaterials().stream().filter(row->row.materialLineId().equals(canonical.materialLineId())).findFirst().orElseThrow();
        assertEquals(route,after.sourceConfirmed(),"Canonical route must follow the inherited real order, not the newly changed master source");
        assertTrue(after.routeConfirmed());
        amount("300",after.requiredQty());amount("0",after.planningUncoveredQty());
        amount("400",h.db.queryForObject("SELECT SUM(requested_qty+public_surplus_qty) FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=? AND status<>'CANCELLED'",BigDecimal.class,c.analysis(),c.material()));
    }
}
