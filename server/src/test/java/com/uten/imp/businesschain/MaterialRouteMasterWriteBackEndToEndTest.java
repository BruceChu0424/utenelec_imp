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

/** Planning follows master defaults and cannot mutate product roles, including through old clients. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
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

    @Test void planningCannotChangeTheMasterRoleAndFailureIsAtomic(){
        Case c=create("role-protected-"+UUID.randomUUID());
        long before=goodsVersion(c.leaf());
        for(String route:List.of("MAKE","SUBCONTRACT")) {
            var failure=assertThrows(com.uten.imp.common.web.ApiException.class,()->confirm(c,route,route));
            assertTrue(failure.getMessage().contains("排产不能修改产品角色"));
            assertEquals("采购",sourceType(c.leaf()));assertEquals(before,goodsVersion(c.leaf()));
            assertEquals("BUY",confirmedRoute(c.line()));
        }
        assertEquals("BUY",material(refresh(c,"unchanged"),c.line()).sourceConfirmed());
    }

    @Test void oldClientsMayConfirmTheSameDefaultWithoutWritingTheMaster(){
        Case c=create("role-confirm-"+UUID.randomUUID());long before=goodsVersion(c.leaf());
        confirm(c,"BUY","same-default");confirm(c,"BUY","repeat-default");
        assertEquals("采购",sourceType(c.leaf()));assertEquals(before,goodsVersion(c.leaf()));
        assertEquals("BUY",storedSuggestion(c.line()));
        AnalysisView second=newAnalysisFor(c,"second");
        assertEquals("BUY",second.flatMaterials().stream().filter(m->m.goodsId().equals(c.leaf())).findFirst().orElseThrow().sourceConfirmed());
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

    @Test void onePlanningAnalysisCannotChangeAnotherOrdersDefault(){
        Case c=create("role-cross-"+UUID.randomUUID());
        AnalysisView second=newAnalysisFor(c,"cross");
        MaterialView line=second.flatMaterials().stream().filter(m->m.goodsId().equals(c.leaf())).findFirst().orElseThrow();
        assertThrows(com.uten.imp.common.web.ApiException.class,()->analyses.saveRoutes(second.analysisId(),
            new RouteRequest(second.version(),second.fingerprint(),"role-cross-"+c.analysis(),
                List.of(new RouteDecision(line.materialLineId(),line.actionGroupKey(),"MAKE",null)))));
        assertEquals("采购",sourceType(c.leaf()));
        assertEquals("BUY",material(refresh(c,"cross-refresh"),c.line()).sourceConfirmed());
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
