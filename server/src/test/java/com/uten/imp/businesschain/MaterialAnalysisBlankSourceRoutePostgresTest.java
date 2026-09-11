package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * F8（2026-09-10）：主档来源为空的 BOM 父件按自制建议展开（子层需求 > 0、可勾选），空来源叶子仍
 * REVIEW；刷新只在主档真的改了来源时清人工确认路线并回传 {@code routeResetCount}，旧快照的 REVIEW
 * 升级为 MAKE 不算事实变更。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>，否则本类 SKIP 且 surefire exit 0（假绿）。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisBlankSourceRoutePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    @Test void blankSourceParentWithBomSuggestsMakeAndKeepsManualRouteUntilTheMasterReallyChanges(){
        String tag="blank-source";
        var w=fixture.seedWorld(tag);
        UUID root=UUID.randomUUID(),parent=UUID.randomUUID(),leaf=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"来源为空回归成品","自制",w.unitId(),w.unitLegacy());
        // 老库迁移/导入允许 source_type 为空：有 BOM 子层的组件 + 无 BOM 的叶子各一。
        fixture.insertGoods(parent,"X-"+tag,"来源为空的组件","",w.unitId(),w.unitLegacy());
        fixture.insertGoods(leaf,"L-"+tag,"来源为空的叶子","",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"2");fixture.insertBom(root,leaf,"1");
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route");
        fixture.loginAs(planner);
        PreviewItem source=new PreviewItem("OTHER",null,root,null,w.unitId(),"manual-"+tag,"主档来源为空回归",
                BusinessTime.today().plusDays(10),new BigDecimal("100"));
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(source)));
        UUID analysis=view.analysisId();

        MaterialView parentRow=byGoods(view,parent);
        assertEquals("MAKE",parentRow.sourceSuggestion(),"有 BOM 子层的空来源件按自制建议");
        assertEquals("REVIEW",byGoods(view,leaf).sourceSuggestion(),"空来源叶子仍为 REVIEW（只影响 UI 预填）");
        MaterialView child=byGoods(view,w.goodsC());
        qty("200",child.requiredQty());assertEquals("ACTIVE",child.requirementState());assertTrue(child.actionable());
        assertEquals(0,view.routeResetCount());

        analyses.saveRoutes(analysis,new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,List.of(
                new RouteDecision(parentRow.materialLineId(),parentRow.actionGroupKey(),"SUBCONTRACT","来源为空，计划部按委外处理"))));
        assertEquals("SUBCONTRACT",byGoods(analyses.detail(analysis),parent).sourceConfirmed());

        // 旧快照的 REVIEW 建议（部署前生成）升级为 MAKE 不算事实变更：人工确认保留，重置数为 0。
        db.update("UPDATE production_material_analysis_materials SET source_suggestion='REVIEW' WHERE analysis_id=? AND goods_id=?",analysis,parent);
        AnalysisView upgraded=refresh(analysis,w.warehouseId(),source,"refresh-legacy-review");
        assertEquals("MAKE",byGoods(upgraded,parent).sourceSuggestion());
        assertEquals("SUBCONTRACT",byGoods(upgraded,parent).sourceConfirmed());
        assertEquals(0,upgraded.routeResetCount());

        // 主档从空补齐为「自制」：建议值仍是 MAKE，不清人工确认。
        db.update("UPDATE goods SET source_type='自制' WHERE id=?",parent);
        AnalysisView filled=refresh(analysis,w.warehouseId(),source,"refresh-fill");
        assertEquals("MAKE",byGoods(filled,parent).sourceSuggestion());
        assertEquals("SUBCONTRACT",byGoods(filled,parent).sourceConfirmed());
        assertEquals(0,filled.routeResetCount());
        qty("200",byGoods(filled,w.goodsC()).requiredQty());

        // 主档真的改了来源（自制→采购）：清人工确认、刷新响应回传 1；子层按 BUY 父路线不展开。
        db.update("UPDATE goods SET source_type='采购' WHERE id=?",parent);
        AnalysisView changed=refresh(analysis,w.warehouseId(),source,"refresh-buy");
        assertEquals("BUY",byGoods(changed,parent).sourceSuggestion());
        assertNull(byGoods(changed,parent).sourceConfirmed());
        assertEquals(1,changed.routeResetCount());
        MaterialView childAfter=byGoods(changed,w.goodsC());
        qty("0",childAfter.requiredQty());assertEquals("INACTIVE_PARENT_ROUTE",childAfter.requirementState());assertFalse(childAfter.actionable());
        assertEquals(0,analyses.detail(analysis).routeResetCount(),"详情响应恒为 0，只有刷新响应带重置数");
    }

    private AnalysisView refresh(UUID analysis,UUID warehouse,PreviewItem source,String key){
        AnalysisView current=analyses.detail(analysis);
        return analyses.preview(new PreviewRequest(analysis,current.version(),current.fingerprint(),warehouse,key+"-"+analysis,List.of(source)));
    }
    private static MaterialView byGoods(AnalysisView view,UUID goodsId){
        return view.flatMaterials().stream().filter(m->goodsId.equals(m.goodsId())).findFirst().orElseThrow();
    }
    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
