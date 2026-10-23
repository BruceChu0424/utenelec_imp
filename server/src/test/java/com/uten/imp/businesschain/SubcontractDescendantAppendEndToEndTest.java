package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
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
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Original paths remain the UI's identity after shared MAKE ownership has moved. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractDescendantAppendEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @ParameterizedTest @ValueSource(ints={1,3})
    void subcontractAppendThroughOriginalNestedPathExposesThePurchaseGapAndIssuesItOnce(int sources) {
        var c=h.create(true,false,"100",true,sources,"1");
        h.setRoute(c,c.child(),"SUBCONTRACT");
        var initial=h.analyses.detail(c.analysis());
        UUID parent=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.child()))
                .findFirst().orElseThrow().materialLineId();
        UUID leaf=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())
                && row.analysisLineId().equals(initial.flatMaterials().stream()
                .filter(value->value.materialLineId().equals(parent)).findFirst().orElseThrow().analysisLineId()))
                .findFirst().orElseThrow().materialLineId();
        String total=Integer.toString(100*sources);
        // The MAKE parent creates canonical descendants. All later operations use original IDs.
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE",total,false))));
        // The initial set contains both original aliases and their canonical copy after MAKE.
        List<UUID> originalParents=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.child()))
                .map(MaterialView::materialLineId).toList();
        List<UUID> originalLeaves=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.material()))
                .map(MaterialView::materialLineId).toList();
        h.writer.submit(c.analysis(),h.command(c,List.of(sourceInput(originalParents,"SUBCONTRACT",total,false))));
        h.writer.submit(c.analysis(),h.command(c,List.of(sourceInput(originalLeaves,"BUY",total,false))));
        var append=h.command(c,List.of(sourceInput(List.of(parent),"SUBCONTRACT","20",true)));
        var added=h.writer.submit(c.analysis(),append);
        assertTrue(h.writer.submit(c.analysis(),append).replayed());
        var after=added.analysis();
        MaterialView originalLeaf=after.flatMaterials().stream().filter(row->row.materialLineId().equals(leaf))
                .findFirst().orElseThrow();
        amount("0",originalLeaf.planningUncoveredQty());
        assertNotNull(originalLeaf.aggregatePreparation());
        amount("20",originalLeaf.aggregatePreparation().planningUncoveredQty());
        assertTrue(originalLeaf.aggregatePreparation().actionable());
        MaterialView originalParent=after.flatMaterials().stream().filter(row->row.materialLineId().equals(parent))
                .findFirst().orElseThrow();
        amount("120",originalParent.aggregatePreparation().orderedQty());
        assertTrue(originalParent.aggregatePreparation().orderedQtyExact());
        var supply=h.command(c,List.of(sourceInput(List.of(leaf),"BUY","20",false)));
        h.writer.submit(c.analysis(),supply);
        assertTrue(h.writer.submit(c.analysis(),supply).replayed());
        var done=h.analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(row->row.materialLineId().equals(leaf)).findFirst().orElseThrow();
        amount("0",done.aggregatePreparation().planningUncoveredQty());
        amount(Integer.toString(100*sources+20),h.db.queryForObject("""
                SELECT SUM(action.requested_qty+action.public_surplus_qty)
                FROM preplan_supply_actions action
                WHERE analysis_id=? AND goods_id=? AND route='BUY' AND status<>'CANCELLED'
                """,BigDecimal.class,c.analysis(),c.material()));
    }

    private GroupInput sourceInput(List<UUID> ids,
                                  String route,String qty,boolean extra) {
        var value=new BigDecimal(qty);
        Map<UUID,BigDecimal> proof=new java.util.LinkedHashMap<>();
        for(UUID id:ids)proof.put(id,value.divide(BigDecimal.valueOf(ids.size())));
        return new GroupInput("original-"+ids.getFirst(),ids,route,value,extra,
                null,null,null,null,null,null,null,BigDecimal.ZERO,proof);
    }
}
