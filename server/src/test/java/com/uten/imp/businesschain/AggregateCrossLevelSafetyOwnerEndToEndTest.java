package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** A non-cyclic repeated component can occupy two independently orderable BOM depths. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateCrossLevelSafetyOwnerEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before() {
        h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();
    }
    @AfterEach void after() { h.after(); }

    @Test void aDeepSafetyOwnerCannotSilentlyAdmitAnEarlierUncoveredSibling() throws Exception {
        var seed=h.createWithChild("5",1);
        UUID root=UUID.randomUUID();
        h.fixture.insertGoods(root,"SAFE-DEPTH-"+root,"cross-level safety root","自制",seed.world().unitId(),seed.world().unitLegacy());
        h.fixture.insertBom(root,seed.material(),"1");
        h.fixture.insertBom(root,seed.common(),"1");
        UUID order=h.fixture.createApprovedOrder(seed.world(),root,"5","100");
        UUID orderItem=h.db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var created=h.analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,seed.world().warehouseId(),
                "cross-level-safety-"+UUID.randomUUID(),List.of(new MaterialAnalysisContracts.PreviewItem(
                "SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("5")))));
        var c=new AggregateMaterialOrderEndToEndTest.Case(seed.world(),created.analysisId(),seed.common(),seed.child(),seed.material(),seed.workshop(),seed.worker());
        h.analyses.saveRoutes(c.analysis(),new MaterialAnalysisContracts.RouteRequest(created.version(),created.fingerprint(),
                "cross-level-routes-"+UUID.randomUUID(),created.flatMaterials().stream().map(row->new MaterialAnalysisContracts.RouteDecision(
                row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?"BUY":"MAKE",null)).toList()));
        h.db.update("UPDATE goods SET min_qty=10 WHERE id=?",c.material());
        var rows=h.analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material()))
                .sorted(Comparator.comparingInt(MaterialAnalysisContracts.MaterialView::level)).toList();
        assertEquals(2,rows.size());
        assertEquals(List.of(1,3),rows.stream().map(MaterialAnalysisContracts.MaterialView::level).toList());
        amount("5",rows.getFirst().requiredQty());amount("10",rows.getLast().requiredQty());
        amount("15",rows.stream().map(MaterialAnalysisContracts.MaterialView::sourceRequiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        var shallow=group("shallow-demand",rows.getFirst().materialLineId(),"5","0",10);
        var deep=group("deep-safety-owner",rows.getLast().materialLineId(),"10","10",11);
        var request=h.request(c,List.of(shallow,deep));
        var before=writeCounts(c);
        var reviewed=h.preview.preview(c.analysis(),request);
        var failure=assertThrows(ApiException.class,()->h.writer.submit(c.analysis(),h.submit(reviewed,request)));
        assertEquals(ErrorCode.CONFLICT,failure.getCode());
        assertEquals(before,writeCounts(c),"a safety admission conflict must not write supply, allocations or replay facts");
        var evidence=new LinkedHashMap<String,Object>();
        evidence.put("goodsId",c.material());evidence.put("levels",rows.stream().map(MaterialAnalysisContracts.MaterialView::level).toList());
        evidence.put("sourceRequiredQty",rows.stream().map(MaterialAnalysisContracts.MaterialView::sourceRequiredQty).toList());
        evidence.put("sourceRequestedQty",List.of(shallow.qty(),deep.qty()));
        evidence.put("confirmedSafetyQty",List.of(shallow.safetyQty(),deep.safetyQty()));
        evidence.put("previewBlockedReasons",reviewed.groups().stream().map(group->group.blockedReason()).toList());
        evidence.put("submitError",failure.getCode().name());evidence.put("submitMessage",failure.getMessage());
        evidence.put("writeCountsBefore",before);evidence.put("writeCountsAfter",writeCounts(c));
        Path output=Path.of(System.getProperty("uten.build.directory","target"),"aggregate-cross-level-safety-owner.json");
        Files.createDirectories(output.toAbsolutePath().getParent());
        beans.getBean(ObjectMapper.class).writerWithDefaultPrettyPrinter().writeValue(output.toFile(),evidence);
        assertTrue(reviewed.groups().stream().anyMatch(group->group.blockedReason()!=null),
                "preview must explain why the earlier shallow sibling cannot execute before its deeper safety owner");
    }

    private List<Long> writeCounts(AggregateMaterialOrderEndToEndTest.Case c) {
        return List.of(h.count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM purchase_request_items WHERE goods_id=?",c.material()));
    }
    private static GroupInput group(String key,UUID source,String qty,String safety,int days) {
        return new GroupInput(key,List.of(source),"BUY",new BigDecimal(qty),false,null,null,null,null,
                BusinessTime.today().plusDays(days),null,null,new BigDecimal(safety));
    }
}
