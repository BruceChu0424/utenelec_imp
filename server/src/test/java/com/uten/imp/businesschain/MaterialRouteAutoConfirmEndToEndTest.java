package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * 「按货品档案自动确认供应方式」挪到服务端 (ADR-102, 2026-09-27).
 *
 * <p>用户实测: 一进物料分析准备页就弹「正在确认物料路线」的全屏遮罩, 要卡一会. 原因是页面拿到
 * 分析后又发一次 PUT /routes, 服务端再整份重算一遍. 现在新建/刷新分析 (POST /preview) 与人工
 * 改路线 (PUT /routes) 在同一次重算、同一事务里直接确认, 响应带回确认了几组; 别的单据顺带
 * 触发的重算不替人确认, 详情里数出还有几组待确认, 页面静默刷新一次即可.
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则整类 SKIP.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialRouteAutoConfirmEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired PlatformTransactionManager transactions;
    @Autowired jakarta.persistence.EntityManager em;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    /**
     * 新建分析一次请求就把「定了的」供应方式全部确认: 顶层自制、采购件、空来源但有 BOM 的组件
     * (按自制, 同事务回写主档)、它下面的采购件; 空来源又无下层的 (REVIEW) 留给人补选.
     * 不再有第二次 PUT /routes (命令日志只有一条 PREVIEW).
     */
    @Test void previewConfirmsEveryDecisiveRouteInTheSameRequest(){
        Tree t=tree("auto-preview");
        UUID planner=planner(t.world(),"auto-preview",true);
        fixture.loginAs(planner);
        long leafVersion=goodsVersion(t.leaf());

        AnalysisView view=create(t,"auto-preview");

        assertEquals(4,view.autoConfirmedRouteCount(),"顶层 + 采购件 + 空来源组件 + 组件下的采购件");
        assertEquals(0,view.pendingAutoConfirmRouteCount());
        assertEquals("MAKE",root(view).sourceConfirmed());
        assertEquals("BUY",byGoods(view,t.leaf()).sourceConfirmed());
        assertEquals("MAKE",byGoods(view,t.mid()).sourceConfirmed());
        assertEquals("BUY",byGoods(view,t.midLeaf()).sourceConfirmed());
        MaterialView review=byGoods(view,t.review());
        assertEquals("REVIEW",review.sourceSuggestion());
        assertNull(review.sourceConfirmed(),"空来源且无下层的行不替人决定");

        assertEquals("自制",sourceType(t.mid()),"与人工确认同一套主档回写");
        assertEquals("采购",sourceType(t.leaf()));
        assertEquals(leafVersion,goodsVersion(t.leaf()),"建议本就来自主档的行不改主档、不抬版本");
        assertEquals(planner,db.queryForObject("SELECT route_confirmed_by FROM production_material_analysis_materials WHERE id=?",
                UUID.class,byGoods(view,t.leaf()).materialLineId()));
        assertEquals(List.of("PREVIEW"),operations(view.analysisId()),"不再补发一次改路线");

        AnalysisView detail=analyses.detail(view.analysisId());
        assertEquals(0,detail.autoConfirmedRouteCount(),"详情响应恒为 0");
        assertEquals(0,detail.pendingAutoConfirmRouteCount());
        assertEquals(view.version(),detail.version(),"确认在换指纹之前, 版本只涨一次");
        assertEquals(view.fingerprint(),detail.fingerprint());
    }

    /**
     * 没有路线维护权限的人新建分析: 一条不确认; 他看到的待确认组数也是 0 (做不了的事不提示).
     * 别的单据顺带触发的后台重算也不替人确认, 能确认路线的人打开详情数出 4 组; 刷新一次就全部确认.
     */
    @Test void withoutRoutePermissionTheDetailCountsPendingRowsUntilAnAuthorizedRefresh(){
        Tree t=tree("auto-pending");
        fixture.loginAs(planner(t.world(),"auto-pending",false));

        AnalysisView view=create(t,"auto-pending");

        assertEquals(0,view.autoConfirmedRouteCount());
        assertEquals(0,view.pendingAutoConfirmRouteCount(),"没有确认能力的账号不报待确认组数");
        assertNull(byGoods(view,t.leaf()).sourceConfirmed());
        assertFalse(view.allowedActions().contains("CONFIRM_ROUTES"),"改路线能力与自动确认同一道闸");

        fixture.loginAs(t.world().superAdminUserId());
        Object target=AopTestUtils.getUltimateTargetObject(analyses);
        new TransactionTemplate(transactions).executeWithoutResult(tx ->
                ReflectionTestUtils.invokeMethod(target,"refreshLocked",view.analysisId()));
        AnalysisView background=analyses.detail(view.analysisId());
        assertNull(byGoods(background,t.leaf()).sourceConfirmed(),"顺带触发的重算不替人确认");
        assertEquals(4,background.pendingAutoConfirmRouteCount());
        assertTrue(background.allowedActions().contains("CONFIRM_ROUTES"));

        AnalysisView refreshed=refresh(t,view.analysisId(),"auto-pending-refresh");

        assertEquals(4,refreshed.autoConfirmedRouteCount());
        assertEquals(0,refreshed.pendingAutoConfirmRouteCount());
        assertEquals("BUY",byGoods(refreshed,t.leaf()).sourceConfirmed());
        assertEquals(t.world().superAdminUserId(),db.queryForObject(
                "SELECT route_confirmed_by FROM production_material_analysis_materials WHERE id=?",
                UUID.class,byGoods(refreshed,t.leaf()).materialLineId()));
    }

    /**
     * 人工把采购件改成自制后, 它下面刚冒出独立需求的子件在同一次改路线请求里按主档确认,
     * 响应带回 1 组; 人工改的那一行保持人的决定.
     */
    @Test void manualRouteChangeConfirmsNewlyExposedChildrenInTheSameResponse(){
        Tree t=tree("auto-manual");
        db.update("UPDATE goods SET source_type='采购' WHERE id=?",t.mid());
        fixture.loginAs(planner(t.world(),"auto-manual",true));
        AnalysisView view=create(t,"auto-manual");
        MaterialView mid=byGoods(view,t.mid());
        assertEquals("BUY",mid.sourceConfirmed());
        assertNull(byGoods(view,t.midLeaf()).sourceConfirmed(),"父件外购时子件没有独立需求, 不确认");

        AnalysisView changed=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),
                "auto-manual-route-"+view.analysisId(),
                List.of(new RouteDecision(mid.materialLineId(),mid.actionGroupKey(),"MAKE","改为自己做"))));

        assertEquals(1,changed.autoConfirmedRouteCount());
        assertEquals("MAKE",byGoods(changed,t.mid()).sourceConfirmed());
        assertEquals("BUY",byGoods(changed,t.midLeaf()).sourceConfirmed());
        assertEquals(0,changed.pendingAutoConfirmRouteCount());
        assertEquals(List.of("PREVIEW","ROUTE"),operations(view.analysisId()));
    }

    /**
     * 自动确认只补空白档案, 不改写别人填过的来源 (2026-09-27 集成复核): 顶层产品已有生产计划时
     * 按自制确认, 档案若写着委外, 档案保持委外、不抬版本; 档案空白时照旧补成自制.
     */
    @Test void automaticConfirmationNeverOverwritesAFilledGoodsMaster(){
        Tree t=tree("auto-keep");
        UUID planner=planner(t.world(),"auto-keep",true);
        fixture.loginAs(planner);
        AnalysisView view=create(t,"auto-keep");
        MaterialView root=root(view);
        assertEquals("MAKE",root.sourceConfirmed());

        clearConfirmation(root.materialLineId());
        db.update("UPDATE goods SET source_type='委外' WHERE id=?",t.root());
        long version=goodsVersion(t.root());
        applyAutomatic(view.analysisId(),planner,root,t.root(),"MAKE");
        assertEquals("MAKE",confirmedRoute(root.materialLineId()));
        assertEquals("委外",sourceType(t.root()),"自动确认不改写已填的档案");
        assertEquals(version,goodsVersion(t.root()));

        clearConfirmation(root.materialLineId());
        db.update("UPDATE goods SET source_type='' WHERE id=?",t.root());
        applyAutomatic(view.analysisId(),planner,root,t.root(),"MAKE");
        assertEquals("自制",sourceType(t.root()),"空白档案照旧补上");
    }

    private void clearConfirmation(UUID material){
        db.update("UPDATE production_material_analysis_materials SET confirmed_route=NULL,route_confirmed_by=NULL,route_confirmed_at=NULL WHERE id=?",material);
    }

    private String confirmedRoute(UUID material){
        return db.queryForObject("SELECT confirmed_route FROM production_material_analysis_materials WHERE id=?",String.class,material);
    }

    /** 写入器是分析包内部类, 这里按反射走与服务端重算同一个 applyAutomatic. */
    private void applyAutomatic(UUID analysis,UUID actor,MaterialView row,UUID goods,String route){
        new TransactionTemplate(transactions).executeWithoutResult(tx -> {
            try{
                String pkg="com.uten.imp.features.production.analysis.";
                Class<?> writer=Class.forName(pkg+"MaterialAnalysisRouteBatchWriter");
                Class<?> change=Class.forName(pkg+"MaterialAnalysisRouteBatchWriter$Change");
                var ctor=writer.getDeclaredConstructor(jakarta.persistence.EntityManager.class);ctor.setAccessible(true);
                var changeCtor=change.getDeclaredConstructor(UUID.class,String.class,UUID.class,String.class,String.class);
                changeCtor.setAccessible(true);
                var method=writer.getDeclaredMethod("applyAutomatic",UUID.class,UUID.class,List.class);method.setAccessible(true);
                method.invoke(ctor.newInstance(em),analysis,actor,
                        List.of(changeCtor.newInstance(row.materialLineId(),row.actionGroupKey(),goods,route,null)));
            }catch(ReflectiveOperationException e){throw new IllegalStateException(e);}
        });
    }

    /** 根(自制) -> 叶子(采购) / 空来源组件 -> 叶子(采购) / 空来源无下层件. */
    private Tree tree(String tag){
        var w=fixture.seedWorld(tag);
        UUID root=UUID.randomUUID(),leaf=UUID.randomUUID(),mid=UUID.randomUUID(),midLeaf=UUID.randomUUID(),review=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"自动确认成品-"+tag,"自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(leaf,"LEAF-"+tag,"自动确认采购件-"+tag,"采购",w.unitId(),w.unitLegacy());
        fixture.insertGoods(mid,"MID-"+tag,"自动确认空来源组件-"+tag,"",w.unitId(),w.unitLegacy());
        fixture.insertGoods(midLeaf,"ML-"+tag,"自动确认组件下采购件-"+tag,"采购",w.unitId(),w.unitLegacy());
        fixture.insertGoods(review,"RV-"+tag,"自动确认空来源叶子-"+tag,"",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,leaf,"1");fixture.insertBom(root,mid,"1");fixture.insertBom(mid,midLeaf,"2");
        fixture.insertBom(root,review,"1");
        return new Tree(w,root,leaf,mid,midLeaf,review,"manual-"+tag);
    }

    private UUID planner(FullChainEndToEndTest.World w,String tag,boolean route){
        return route
                ? fixture.createUserWithPerms(w,"planner-"+tag,"production_material_analysis:view",
                        "production_material_analysis:manage","production_material_analysis:route")
                : fixture.createUserWithPerms(w,"planner-"+tag,"production_material_analysis:view",
                        "production_material_analysis:manage");
    }

    private AnalysisView create(Tree t,String key){
        return analyses.preview(new PreviewRequest(null,null,null,t.world().warehouseId(),"preview-"+key,
                List.of(source(t))));
    }

    private AnalysisView refresh(Tree t,UUID analysis,String key){
        AnalysisView current=analyses.detail(analysis);
        return analyses.preview(new PreviewRequest(analysis,current.version(),current.fingerprint(),
                t.world().warehouseId(),key+"-"+analysis,List.of(source(t))));
    }

    private static PreviewItem source(Tree t){
        return new PreviewItem("OTHER",null,t.root(),null,t.world().unitId(),t.sourceRef(),"自动确认供应方式回归",
                BusinessTime.today().plusDays(10),new BigDecimal("100"));
    }

    private List<String> operations(UUID analysis){
        return db.queryForList("SELECT operation FROM production_material_analysis_commands WHERE analysis_id=? ORDER BY created_at,operation",
                String.class,analysis);
    }

    private String sourceType(UUID goods){
        return db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,goods);
    }

    private long goodsVersion(UUID goods){
        return db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods);
    }

    private static MaterialView root(AnalysisView view){
        return view.flatMaterials().stream().filter(row->"ROOT_SUPPLY".equals(row.nodeRole())).findFirst().orElseThrow();
    }

    private static MaterialView byGoods(AnalysisView view,UUID goods){
        return view.flatMaterials().stream().filter(row->goods.equals(row.goodsId())&&!"ROOT_SUPPLY".equals(row.nodeRole()))
                .findFirst().orElseThrow();
    }

    private record Tree(FullChainEndToEndTest.World world,UUID root,UUID leaf,UUID mid,UUID midLeaf,UUID review,String sourceRef){}
}
