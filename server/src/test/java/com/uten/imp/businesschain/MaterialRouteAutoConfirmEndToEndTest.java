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
    @Autowired com.uten.imp.features.production.analysis.AggregateMaterialOrderPreviewService aggregatePreviews;
    @Autowired PlatformTransactionManager transactions;
    @Autowired jakarta.persistence.EntityManager em;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void manualPlanWithTwoLeafProductsConfirmsTheirMasterRoutesWithoutAnotherSelection(){
        var w=fixture.seedWorld("manual-leaf-routes");
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        fixture.insertGoods(first,"LEAF-MAKE-1","手工计划自制料1","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(second,"LEAF-MAKE-2","手工计划自制料2","自制",w.unitId(),w.unitLegacy());
        fixture.loginAs(fixture.createUserWithPerms(w,"manual-leaf-planner",
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route"));
        List<PreviewItem> sources=List.of(manualSource(w,first,"manual-leaf"),manualSource(w,second,"manual-leaf"));

        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"manual-leaf-preview",sources));

        assertEquals(2,view.autoConfirmedRouteCount());
        assertEquals(0,view.pendingAutoConfirmRouteCount());
        assertEquals(2,view.flatMaterials().size());
        assertTrue(view.flatMaterials().stream().allMatch(row->"MAKE".equals(row.sourceConfirmed())));
        assertTrue(view.products().stream().allMatch(ProductView::canSchedule));
        assertEquals(List.of("PREVIEW"),operations(view.analysisId()));
    }

    @Test void manualPlanInheritsPurchaseAndSubcontractProductRoutesFromTheGoodsMaster(){
        var w=fixture.seedWorld("manual-external-routes");
        UUID buy=UUID.randomUUID(),subcontract=UUID.randomUUID(),buyChild=UUID.randomUUID();
        fixture.insertGoods(buy,"ROOT-BUY-MASTER","手工计划采购产品","采购",w.unitId(),w.unitLegacy());
        fixture.insertGoods(subcontract,"ROOT-SUB-MASTER","手工计划委外产品","委外",w.unitId(),w.unitLegacy());
        fixture.insertGoods(buyChild,"ROOT-BUY-CHILD","采购产品的参考BOM物料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(buy,buyChild,"2");
        fixture.insertBom(subcontract,w.goodsC(),"1");
        fixture.loginAs(fixture.createUserWithPerms(w,"manual-external-planner",
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route"));
        List<PreviewItem> sources=List.of(manualSource(w,buy,"manual-external"),manualSource(w,subcontract,"manual-external"));

        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"manual-external-preview",sources));

        assertEquals("BUY",rootByGoods(view,buy).sourceConfirmed());
        assertEquals("SUBCONTRACT",rootByGoods(view,subcontract).sourceConfirmed());
        assertEquals("采购",sourceType(buy));
        assertEquals("委外",sourceType(subcontract));
        assertTrue(view.flatMaterials().stream().noneMatch(row->buyChild.equals(row.goodsId())),
                "采购根在本轮确认后就不展开制造备料");
        MaterialView subcontractMaterial=byGoods(view,w.goodsC());
        assertEquals(0,new BigDecimal("100").compareTo(subcontractMaterial.requiredQty()));
        assertEquals("DESIGN",subcontractMaterial.usageBasis());
        assertEquals("SUBCONTRACT_OUTBOUND",subcontractMaterial.usageReason());
        assertEquals(0,view.pendingAutoConfirmRouteCount());
        assertTrue(view.products().stream().noneMatch(ProductView::canSchedule));
        assertEquals(List.of("PREVIEW"),operations(view.analysisId()));

        db.update("UPDATE goods SET source_type='自制' WHERE id=?",buy);
        AnalysisView refreshed=analyses.preview(new PreviewRequest(view.analysisId(),view.version(),view.fingerprint(),
                w.warehouseId(),"manual-external-refresh",sources));
        assertEquals("BUY",rootByGoods(refreshed,buy).sourceConfirmed(),"已确认路线不会被档案后续变化替换");
        assertEquals("MAKE",rootByGoods(refreshed,buy).sourceSuggestion(),"刷新只更新档案建议");
        assertEquals("SUBCONTRACT",rootByGoods(refreshed,subcontract).sourceConfirmed());
        assertEquals(0,refreshed.autoConfirmedRouteCount());
    }

    @Test void manualPlanWithoutAMasterRouteOrBomRequiresAnExplicitChoice(){
        var w=fixture.seedWorld("manual-unknown-route");
        UUID goods=UUID.randomUUID();
        fixture.insertGoods(goods,"ROOT-UNKNOWN-MASTER","未维护供应方式产品","",w.unitId(),w.unitLegacy());
        fixture.loginAs(fixture.createUserWithPerms(w,"manual-unknown-planner",
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route"));
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"manual-unknown-preview",
                List.of(manualSource(w,goods,"manual-unknown"))));
        assertEquals("REVIEW",rootByGoods(view,goods).sourceSuggestion());
        assertNull(rootByGoods(view,goods).sourceConfirmed());
        assertEquals(0,view.autoConfirmedRouteCount());
        assertFalse(view.products().getFirst().canSchedule());
        assertEquals("",sourceType(goods),"没有档案或BOM依据时不擅自补写为自制");
    }

    private static PreviewItem manualSource(FullChainEndToEndTest.World w,UUID goods,String ref){
        return new PreviewItem("STOCK",null,goods,null,w.unitId(),ref,"手工计划供应方式回归",
                BusinessTime.today().plusDays(10),new BigDecimal("100"));
    }

    private static MaterialView rootByGoods(AnalysisView view,UUID goods){
        return view.flatMaterials().stream().filter(row->goods.equals(row.goodsId())&&"ROOT_SUPPLY".equals(row.nodeRole()))
                .findFirst().orElseThrow();
    }

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

        assertEquals("",sourceType(t.mid()),"计划快照可按既有 BOM 推导，但不能补写主档角色");
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

    @Test void coveredStockStillConfirmsItsMasterSourceOnCreateRefreshAndExplicitConfirmation(){
        Tree t=tree("covered-master-source");
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,1000)",t.world().warehouseId(),t.leaf());
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,1000)",t.world().warehouseId(),t.review());
        fixture.loginAs(planner(t.world(),"covered-master-source",true));
        long masterVersion=goodsVersion(t.leaf());

        AnalysisView created=create(t,"covered-master-source");
        MaterialView covered=byGoods(created,t.leaf());
        assertEquals(0,new BigDecimal("100").compareTo(covered.requiredQty()));
        assertEquals(0,new BigDecimal("100").compareTo(covered.allocatedAvailableQty()));
        assertEquals(0,covered.shortageQty().signum());
        assertEquals("BUY",covered.sourceConfirmed());
        assertFalse(covered.actionable(),"物理补缺/让料资格不因来源确认而扩大");
        assertNotEquals("ROUTE_PENDING",covered.flowStage());
        assertTrue(covered.aggregatePreparation().actionable(),"显式公共备货仍有合法来源上下文");
        MaterialView unknown=byGoods(created,t.review());
        assertEquals(0,unknown.shortageQty().signum());
        assertNull(unknown.sourceConfirmed(),"即使库存覆盖，也不能替空主档虚构来源");
        assertNotEquals("ROUTE_PENDING",unknown.flowStage(),"库存已覆盖不能误报成来源待补缺");

        clearConfirmation(covered.materialLineId());
        AnalysisView refreshed=refresh(t,created.analysisId(),"covered-master-refresh");
        assertEquals("BUY",byGoods(refreshed,t.leaf()).sourceConfirmed());
        assertEquals(0,byGoods(refreshed,t.leaf()).shortageQty().signum());

        clearConfirmation(covered.materialLineId());
        AnalysisView before=analyses.detail(created.analysisId());
        AnalysisView confirmed=analyses.saveRoutes(before.analysisId(),new RouteRequest(before.version(),before.fingerprint(),
                "covered-explicit-confirm",List.of(new RouteDecision(covered.materialLineId(),covered.actionGroupKey(),"BUY",null))));
        assertEquals("BUY",byGoods(confirmed,t.leaf()).sourceConfirmed());
        assertEquals(0,new BigDecimal("100").compareTo(byGoods(confirmed,t.leaf()).allocatedAvailableQty()));
        assertEquals(masterVersion,goodsVersion(t.leaf()),"计划确认只写快照，不修改货品主档");
        fixture.loginAs(t.world().superAdminUserId());
        var input=new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput(
                "fresh-covered-public",List.of(covered.materialLineId()),"BUY",new BigDecimal("5"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO);
        var preview=aggregatePreviews.preview(confirmed.analysisId(),
                new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.PreviewRequest(
                        confirmed.version(),confirmed.fingerprint(),"fresh-covered-public-preview",t.world().warehouseId(),
                        BusinessTime.today(),BusinessTime.today().plusDays(10),false,List.of(input)));
        var publicOrder=preview.groups().getFirst();
        assertNull(publicOrder.blockedReason());
        assertEquals(0,new BigDecimal("5").compareTo(publicOrder.publicExtraQty()));
        assertTrue(publicOrder.sources().stream().allMatch(part->part.allocatedQty().signum()==0),
                "本批已绑定现货覆盖的需求不能被额外公共备货再次占用");
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
    @Test void planningCannotChangeTheRoleAndANewAnalysisReadsTheMasterDefault(){
        Tree t=tree("auto-master-only");
        db.update("UPDATE goods SET source_type='采购' WHERE id=?",t.mid());
        fixture.loginAs(planner(t.world(),"auto-master-only",true));
        AnalysisView view=create(t,"auto-master-only");MaterialView mid=byGoods(view,t.mid());
        assertEquals("BUY",mid.sourceConfirmed());
        assertThrows(com.uten.imp.common.web.ApiException.class,()->analyses.saveRoutes(view.analysisId(),
            new RouteRequest(view.version(),view.fingerprint(),"reject-role-"+view.analysisId(),
                List.of(new RouteDecision(mid.materialLineId(),mid.actionGroupKey(),"MAKE",null)))));
        assertEquals("采购",sourceType(t.mid()));assertEquals(List.of("PREVIEW"),operations(view.analysisId()));
        // Simulate an independent, authorized master-data edit. Planning itself never performs this update.
        db.update("UPDATE goods SET source_type='自制' WHERE id=?",t.mid());
        AnalysisView next=analyses.preview(new PreviewRequest(null,null,null,t.world().warehouseId(),"master-new-analysis",
            List.of(new PreviewItem("OTHER",null,t.root(),null,t.world().unitId(),t.sourceRef()+"-new",
                "主档默认来源回归",BusinessTime.today().plusDays(10),new BigDecimal("100")))));
        assertEquals("MAKE",byGoods(next,t.mid()).sourceConfirmed());
        assertEquals("BUY",byGoods(next,t.midLeaf()).sourceConfirmed());
    }

    /**
     * 自动确认只写分析快照, 不回写货品主档 (2026-09-27 集成复核): 顶层产品已有生产计划时
     * 按自制确认, 档案若写着委外, 档案保持委外、不抬版本; 档案空白时仍保留空白.
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
        assertEquals("",sourceType(t.root()),"计划自动确认也不能补写货品主档");
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
