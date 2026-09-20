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
 * 供应方式单一事实源 = 货品主档 goods.source_type (2026-09-16)。
 *
 * <p>用户实测口径：「在物料分析准备页改了供应方式，下次进来还是老的。」根因是确认路线
 * 只写分析行 confirmed_route、货品主档从没更新，而新分析的建议路线又是从主档算出来的。
 * 本类用真实库锁住改完之后的四条事实：
 * <ol>
 *   <li>确认路线同事务回写主档 (BUY -> 采购、MAKE -> 自制、SUBCONTRACT -> 委外)，真改了抬
 *       goods.version，本行 source_suggestion 同时对齐成确认值；</li>
 *   <li><b>同一分析再刷新一次，确认不被清掉</b>——本轮最关键的断言：主档回写后刷新算出的
 *       建议 = 刚确认的值，若本行 source_suggestion 还停在旧建议，就会被
 *       NODE_FACT_CHANGED_CONDITION 当成「主档事实变更」把确认清掉 (反馈环)；</li>
 *   <li>改确认另一条路线再回写一次；相同值再确认不再抬 version (值没变不落盘)；</li>
 *   <li>同一货品新建的第二份分析，建议路线直接来自主档 (/last-routes 记忆已整套退役)。</li>
 * </ol>
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>：本类 (与 FullChain/Scale 同款门控)
 * 未设置时全部 SKIP，surefire 仍 exit 0，会出现「全绿但没跑」的假象。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialRouteMasterWriteBackEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService workshops;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    /**
     * 确认「自制」把主档从采购改成自制并抬 version；紧接着的刷新不得把这次确认清掉。
     * 第二条就是反馈环回归：主档回写与本行 source_suggestion 对齐必须在同一条 UPDATE 里，
     * 少一半刷新就会看到「建议变了」而静默清空确认。
     */
    @Test void confirmingMakeWritesTheGoodsMasterAndSurvivesTheNextRefresh(){
        Case c=create("route-master-make");
        assertEquals("采购",sourceType(c.leaf()),"夹具起点：叶子件主档来源是采购");
        long versionBefore=goodsVersion(c.leaf());

        confirm(c,"MAKE","make");

        assertEquals("自制",sourceType(c.leaf()));
        assertEquals(versionBefore+1,goodsVersion(c.leaf()),"人工决定的回写要抬主档版本");
        assertEquals("MAKE",confirmedRoute(c.line()));
        assertEquals("MAKE",storedSuggestion(c.line()),
                "本行建议必须对齐成确认值，否则下一次刷新会把确认当成主档事实变更清掉");

        AnalysisView refreshed=refresh(c,"after-make");

        assertEquals(0,refreshed.routeResetCount(),"主档按新来源算出的建议与本行一致，零条确认被清");
        assertEquals("MAKE",confirmedRoute(c.line()));
        assertEquals("MAKE",material(refreshed,c.line()).sourceConfirmed());
        assertEquals("自制",sourceType(c.leaf()),"刷新只读主档，不反向改写它");
    }

    /**
     * 改确认「委外」再回写一次；相同值重复确认不再抬 version；同一货品新建的第二份分析
     * 直接按主档给出 SUBCONTRACT 建议——这正是用户要的「改过的供应方式下次进来就是新值」。
     */
    @Test void reconfirmingSubcontractRewritesTheMasterAndSeedsTheNextAnalysisSuggestion(){
        Case c=create("route-master-sub");
        confirm(c,"MAKE","make");
        long afterMake=goodsVersion(c.leaf());

        confirm(c,"SUBCONTRACT","subcontract");

        assertEquals("委外",sourceType(c.leaf()));
        assertEquals(afterMake+1,goodsVersion(c.leaf()));

        confirm(c,"SUBCONTRACT","subcontract-again");

        assertEquals("委外",sourceType(c.leaf()));
        assertEquals(afterMake+1,goodsVersion(c.leaf()),"值没变不落盘，主档版本不动");

        AnalysisView second=newAnalysisFor(c,"second");

        MaterialView line=second.flatMaterials().stream().filter(m->m.goodsId().equals(c.leaf()))
                .findFirst().orElseThrow();
        assertEquals("SUBCONTRACT",line.sourceSuggestion(),"新分析的建议路线只从货品主档来");
        assertNull(line.sourceConfirmed(),"建议不是确认：新分析仍要人再确认一次");
    }

    @Test void workshopLearningRejectsStaleEditorsAndDoesNotReturnResignedWorkers() {
        Case c = create("workshop-defaults");
        UUID workshop = UUID.randomUUID();
        db.update("""
                INSERT INTO departments(id,code,name,parent_id,level)
                SELECT ?,?,'默认车间',id,'二级班组' FROM departments WHERE code='DEPT_PROD'
                """, workshop, "WS-DEFAULT-" + workshop);
        long before = goodsVersion(c.root());
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(tx ->
                workshops.learnSelection(c.root(), workshop, c.world().employeeId(), c.world().employeeId()));
        assertEquals(before + 1, goodsVersion(c.root()));
        assertEquals(0, db.update("UPDATE goods SET owning_workshop_department_id=NULL WHERE id=? AND version=?",
                c.root(), before));
        assertEquals(c.world().employeeId(), workshops.findValidByGoodsIds(java.util.Set.of(c.root()))
                .getFirst().responsibleEmployeeId());
        db.update("UPDATE employees SET status='resigned' WHERE id=?", c.world().employeeId());
        assertNull(workshops.findValidByGoodsIds(java.util.Set.of(c.root())).getFirst().responsibleEmployeeId());
    }

    @Test void anotherAnalysisChangingMasterDefaultsDoesNotClearExistingConfirmedRoutes() {
        Case c = create("route-master-cross");
        confirm(c, "BUY", "buy");
        AnalysisView second = newAnalysisFor(c, "cross");
        MaterialView secondLine = second.flatMaterials().stream().filter(m -> m.goodsId().equals(c.leaf()))
                .findFirst().orElseThrow();
        analyses.saveRoutes(second.analysisId(), new RouteRequest(second.version(), second.fingerprint(),
                "cross-confirm-" + c.analysis(), List.of(new RouteDecision(secondLine.materialLineId(),
                secondLine.actionGroupKey(), "MAKE", null))));
        assertEquals("自制", sourceType(c.leaf()));
        AnalysisView refreshed = refresh(c, "cross-refresh");
        assertEquals("BUY", material(refreshed, c.line()).sourceConfirmed());
        assertEquals(0, refreshed.routeResetCount());
    }

    /** 根(自制成品) -> 叶子件(主档「采购」)：一条叶子物料行，改路线不牵扯任何子层展开。 */
    private Case create(String tag){
        var w=fixture.seedWorld(tag);
        UUID root=UUID.randomUUID(),leaf=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"来源回写成品-"+tag,"自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(leaf,"LEAF-"+tag,"来源回写叶子件-"+tag,"采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,leaf,"1");
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage",
                "production_material_analysis:route","production_material_analysis:notify",
                "production_material_analysis:generate","production_plan:view","production_plan:approve");
        fixture.loginAs(planner);
        String sourceRef="manual-"+tag;
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "preview-"+tag,List.of(sourceItem(w,root,sourceRef))));
        UUID line=view.flatMaterials().stream().filter(m->m.goodsId().equals(leaf))
                .map(MaterialView::materialLineId).findFirst().orElseThrow();
        return new Case(w,view.analysisId(),root,leaf,line,planner,sourceRef);
    }

    /** 同一货品的第二份分析：换来源单号与幂等键(来源单号在未删除的非销售来源里全局唯一)。 */
    private AnalysisView newAnalysisFor(Case c,String tag){
        return analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),
                "preview-"+tag+"-"+c.analysis(),
                List.of(sourceItem(c.world(),c.root(),c.sourceRef()+"-"+tag))));
    }

    private static PreviewItem sourceItem(FullChainEndToEndTest.World w,UUID root,String sourceRef){
        return new PreviewItem("OTHER",null,root,null,w.unitId(),sourceRef,"供应方式回写回归",
                BusinessTime.today().plusDays(10),new BigDecimal("100"));
    }

    /** 刷新 = 原样重发本分析的来源行(POST /preview)，走与页面刷新同一条路径。 */
    private AnalysisView refresh(Case c,String key){
        AnalysisView view=analyses.detail(c.analysis());
        ProductView source=view.products().stream().filter(row->"OTHER".equals(row.sourceType()))
                .findFirst().orElseThrow();
        return analyses.preview(new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),
                c.world().warehouseId(),key+"-"+c.analysis(),
                List.of(new PreviewItem("OTHER",null,c.root(),null,c.world().unitId(),c.sourceRef(),
                        source.sourceReason(),source.deliveryDate(),source.requestedQty()))));
    }

    /** saveRoutes 每次都换版本，所以确认前必须重新 detail 拿最新 version/fingerprint。 */
    private AnalysisView confirm(Case c,String route,String key){
        AnalysisView view=analyses.detail(c.analysis());
        return analyses.saveRoutes(c.analysis(),new RouteRequest(view.version(),view.fingerprint(),
                "routes-"+c.analysis()+"-"+key,
                List.of(new RouteDecision(c.line(),material(view,c.line()).actionGroupKey(),route,null))));
    }

    private String sourceType(UUID goods){
        return db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,goods);
    }

    private long goodsVersion(UUID goods){
        return db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods);
    }

    private String confirmedRoute(UUID materialLineId){
        return db.queryForObject("SELECT confirmed_route FROM production_material_analysis_materials WHERE id=?",
                String.class,materialLineId);
    }

    private String storedSuggestion(UUID materialLineId){
        return db.queryForObject("SELECT source_suggestion FROM production_material_analysis_materials WHERE id=?",
                String.class,materialLineId);
    }

    private static MaterialView material(AnalysisView view,UUID id){
        return view.flatMaterials().stream().filter(row->row.materialLineId().equals(id))
                .findFirst().orElseThrow();
    }

    private record Case(FullChainEndToEndTest.World world,UUID analysis,UUID root,UUID leaf,
            UUID line,UUID planner,String sourceRef){}
}
