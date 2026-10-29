package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractPublicResponsibilityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    // 本类 approve 的委外退货单没有配套 AP 贷项，属于共享库残留；不清理会让后续类的
    // 总账 generate 撞「退货成本未完整核定」守卫（ProcurementReturnCostGlProjection 按当期全库扫描）。
    private final java.util.List<java.util.UUID> approvedSubcontractReturns = new java.util.ArrayList<>();
    @BeforeEach void before() { h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before(); }
    @AfterEach void after() {
        for (java.util.UUID id : approvedSubcontractReturns) {
            h.db.update("UPDATE subcontract_returns SET is_deleted=true WHERE id=? AND NOT is_deleted", id);
        }
        approvedSubcontractReturns.clear();
        h.after();
    }

    @Test void aDifferentDatePublicBatchAddsItsRealBomWithoutAddingPrivateDemand() {
        var c=prepare(false,false);var publicBatch=submitPublic(c,"2",Map.of());
        assertPublicBudget(publicBatch,"2",1);
        assertChildren(c,publicBatch);
        var refreshed=refresh(c.c());assertChildren(c,publicBatch);assertEquals(c.salesDemand(),salesDemand(refreshed));
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void unequalSourcesAndAliasesOfOnePhysicalParentConservePublicOutput(boolean aliases) {
        var c=prepare(true,aliases);
        Map<UUID,BigDecimal> intent=aliases?scaledIntent(c,"3"):Map.of();
        var publicBatch=submitPublic(c,"3",intent);
        assertPublicBudget(publicBatch,"3",aliases?1:2);
        assertChildren(c,publicBatch);
        if(!aliases) {
            var shares=responsibilities(action(publicBatch)).values().stream().sorted().toList();
            amount("1",shares.get(0));amount("2",shares.get(1));
        }
        assertEquals(c.salesDemand(),salesDemand(refresh(c.c())));assertChildren(c,publicBatch);
    }

    @Test void eachAppendKeepsItsOwnPublicIntentInsteadOfReassigningTheFirstDelta() {
        var c=prepare(true,false);List<UUID> ids=c.originals();
        var first=submitPublic(c,"3",Map.of(ids.get(0),new BigDecimal("3"),ids.get(1),BigDecimal.ZERO));
        var second=submitPublic(c,"3",Map.of(ids.get(0),BigDecimal.ZERO,ids.get(1),new BigDecimal("3")));
        assertEquals(first.batchId(),second.batchId());assertPublicBudget(second,"6",2);
        responsibilities(action(second)).values().forEach(qty->amount("3",qty));
        assertChildren(c,second);assertEquals(c.salesDemand(),salesDemand(refresh(c.c())));
    }

    @Test void issuingReturningAndPartlyReceivingPublicOutputNeverCreatesDuplicateMaterialShortage() {
        var c=prepare(false,false);var publicBatch=submitPublic(c,"2",Map.of());
        UUID action=action(publicBatch);UUID parent=c.parents().getFirst();
        UUID material=c.c().child();h.receive(c.c(),material,"7");
        UUID ordered=approveSubcontract(c,publicBatch,"2");
        var issues=h.fixture.drawAndIssueSubcontract(ordered,new BigDecimal("2"),"public-owner-issue-"+UUID.randomUUID());
        assertEquals(1,issues.size());assertNoShortage(c,parent,"7");
        UUID issueItem=h.db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted",UUID.class,issues.getFirst());
        UUID receipt=receiveSubcontract(c,ordered,"1");assertNoShortage(c,parent,"6");
        assertEquals("IN_PROGRESS",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));

        var returned=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();
        var w=c.c().world();returned.setBillDate(BusinessTime.today());returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());
        returned.setCurrencyId(w.currencyId());returned.setExchangeRate(BigDecimal.ONE);returned.setTaxRate(BigDecimal.ZERO);
        returned.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"subcontractOrderSettlementMethodOf",ordered));
        var product=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();
        product.setGoodsId(c.targetGoods());product.setOrderItemId(ordered);product.setUnitId(w.unitId());product.setUnitRate(BigDecimal.ONE);
        product.setQty(BigDecimal.ONE);product.setPrice(new BigDecimal("30"));
        product.setReceiptItemId(h.db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=? AND NOT is_deleted",UUID.class,receipt));
        returned.setItems(List.of(product));var returns=beans.getBean(com.uten.imp.features.subcontract.ret.SubcontractReturnService.class);
        var subcontractReturnId=returns.create(returned).getId();returns.approve(subcontractReturnId);
        approvedSubcontractReturns.add(subcontractReturnId);
        assertNoShortage(c,parent,"7");

        var materialReturn=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();
        materialReturn.setBillDate(BusinessTime.today());materialReturn.setSupplierId(w.supplierId());materialReturn.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();
        line.setGoodsId(material);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);
        line.setMaterialIssueItemId(issueItem);line.setOrderItemId(ordered);line.setParentGoodsId(c.targetGoods());materialReturn.setItems(List.of(line));
        var materialReturns=beans.getBean(com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService.class);
        materialReturns.approve(materialReturns.create(materialReturn).getId());assertNoShortage(c,parent,"7");
        assertEquals(0,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",action));
        assertEquals(c.salesDemand(),salesDemand(h.analyses.detail(c.c().analysis())));
    }

    private Prepared prepare(boolean twoSources,boolean aliases) {
        // Keep every direct BOM ratio one, including the aliased subcontract level.
        var c=h.create(true,false,twoSources?"10":"5",true,twoSources?2:1,"1");
        if(twoSources) {
            var view=h.analyses.detail(c.analysis());var items=new ArrayList<>(sourceInputs(view));
            // A refresh may change analysed quantities, but cannot add a new source identity.
            // The first approved order still has ten available; analyse five of it and ten of the second.
            var first=items.getFirst();
            items.set(0,new PreviewItem("SALES_ORDER_ITEM",first.salesOrderItemId(),null,null,null,null,null,first.deliveryDate(),new BigDecimal("5")));
            h.analyses.preview(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest(c.analysis(),view.version(),view.fingerprint(),
                    c.world().warehouseId(),"public-owner-add-source-"+UUID.randomUUID(),items));
        }
        UUID target=aliases?c.child():c.common();h.setRoute(c,target,"SUBCONTRACT");
        var initial=h.analyses.detail(c.analysis());
        List<UUID> originals=initial.flatMaterials().stream().filter(row->row.goodsId().equals(target)&&row.nodeRole().equals("BOM_COMPONENT"))
                .map(MaterialView::materialLineId).sorted().toList();
        Map<UUID,BigDecimal> sourceQty=initial.flatMaterials().stream().filter(row->originals.contains(row.materialLineId()))
                .collect(Collectors.toMap(MaterialView::materialLineId,MaterialView::sourceRequiredQty));
        String total=twoSources?"15":"5";
        if(aliases)h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE",total,false))));
        var group=group(originals,total,false,null,aliases?sourceQty:Map.of());
        var privateBatch=h.writer.submit(c.analysis(),h.command(c,List.of(group))).batches().getFirst();
        var before=h.analyses.detail(c.analysis());
        List<UUID> parents=privateBatch.sources().stream().map(SourcePreview::materialLineId).distinct().toList();
        Map<UUID,ChildBaseline> children=new LinkedHashMap<>();
        for(UUID parent:parents) {
            var parentRow=material(before,parent);var child=child(before,parentRow,aliases?c.material():c.child());
            children.put(parent,new ChildBaseline(child.materialLineId(),child.requiredQty(),child.sourceRequiredQty()));
        }
        return new Prepared(c,target,aliases,originals,sourceQty,parents,children,salesDemand(before));
    }

    private BatchResult submitPublic(Prepared c,String qty,Map<UUID,BigDecimal> intent) {
        var group=group(c.originals(),qty,true,BusinessTime.today().plusDays(11),intent);
        var request=h.command(c.c(),List.of(group));var result=h.writer.submit(c.c().analysis(),request);
        assertTrue(h.writer.submit(c.c().analysis(),request).replayed());return result.batches().getFirst();
    }
    private GroupInput group(List<UUID> ids,String qty,boolean extra,java.time.LocalDate delivery,Map<UUID,BigDecimal> intent) {
        return new GroupInput("public-responsibility",ids,"SUBCONTRACT",new BigDecimal(qty),extra,
                null,null,null,null,delivery,null,null,BigDecimal.ZERO,intent);
    }
    private Map<UUID,BigDecimal> scaledIntent(Prepared c,String total) {
        BigDecimal sum=c.sourceQty().values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
        Map<UUID,BigDecimal> out=new LinkedHashMap<>();c.originals().forEach(id->out.put(id,c.sourceQty().get(id).multiply(new BigDecimal(total)).divide(sum)));
        return out;
    }
    private Map<UUID,BigDecimal> responsibilities(UUID action) {
        try {
            var ownerClass=Class.forName("com.uten.imp.features.production.analysis.SubcontractPublicResponsibilityProjection");
            String owners=(String)ReflectionTestUtils.getField(ownerClass,"OWNERS_FOR_ACTION_SQL");
            Map<UUID,BigDecimal> out=new LinkedHashMap<>();
            h.db.query("SELECT responsibility.analysis_material_id,responsibility.qty FROM preplan_supply_actions action CROSS JOIN LATERAL ("+owners+") responsibility WHERE action.id=?",
                    row->{out.put(row.getObject(1,UUID.class),row.getBigDecimal(2));},action);return out;
        } catch(ClassNotFoundException error) { throw new AssertionError(error); }
    }
    private void assertPublicBudget(BatchResult batch,String expected,int owners) {
        UUID action=action(batch);var shares=responsibilities(action);assertEquals(owners,shares.size());
        amount(expected,shares.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        assertEquals(0,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",action));
    }
    private void assertChildren(Prepared c,BatchResult batch) {
        var view=h.analyses.detail(c.c().analysis());var shares=responsibilities(action(batch));
        c.children().forEach((parent,before)->{
            var after=material(view,before.material());
            amount(before.required().add(shares.getOrDefault(parent,BigDecimal.ZERO)).toPlainString(),after.requiredQty());
            amount(before.sourceRequired().toPlainString(),after.sourceRequiredQty());
        });
    }
    private void assertNoShortage(Prepared c,UUID parent,String required) {
        var view=refresh(c.c());var row=material(view,c.children().get(parent).material());
        amount(required,row.requiredQty());amount("0",row.planningUncoveredQty());
    }
    private UUID approveSubcontract(Prepared c,BatchResult batch,String qty) {
        UUID item=h.db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,action(batch));
        UUID order=ReflectionTestUtils.invokeMethod(h.fixture,"createSubcontractOrderFromApplication",c.c().world(),c.targetGoods(),item,qty);
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",c.c().world());
        var finance=beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class);
        finance.submit("SUBCONTRACT",order);h.fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(h.fixture,"approvePendingFinance","SUBCONTRACT",order);
        h.fixture.loginAs(c.c().world().superAdminUserId());return h.db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
    }
    private UUID receiveSubcontract(Prepared c,UUID ordered,String qty) {
        var w=c.c().world();var request=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"subcontractOrderSettlementMethodOf",ordered));
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setGoodsId(c.targetGoods());line.setOrderItemId(ordered);
        line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("30"));request.setItems(List.of(line));
        var receipts=beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class);UUID receipt=receipts.create(request).getId();receipts.approve(receipt);
        UUID inspection=h.db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receipt);
        beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class).dispose("SUBCONTRACT",receipt,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"公共回厂责任回归","public-owner-pass-"+UUID.randomUUID()));
        h.fixture.loginAs(ReflectionTestUtils.invokeMethod(h.fixture,"createIqcWarehouseConfirmer",w,"public-owner-keeper-"+inspection));
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest stock=ReflectionTestUtils.invokeMethod(h.fixture,"latestIqcStockInRequest",
                "SUBCONTRACT",receipt,inspection,new BigDecimal(qty),"public-owner-stock-"+UUID.randomUUID(),"PUBLIC-OWNER");
        beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class).confirm("SUBCONTRACT",receipt,stock);
        ReflectionTestUtils.invokeMethod(h.fixture,"drainCosts",w);h.fixture.loginAs(w.superAdminUserId());return receipt;
    }
    private AnalysisView refresh(AggregateMaterialOrderEndToEndTest.Case c) {
        var view=h.analyses.detail(c.analysis());return h.analyses.preview(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest(
                c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),"public-owner-refresh-"+UUID.randomUUID(),sourceInputs(view)));
    }
    private static List<PreviewItem> sourceInputs(AnalysisView view) { return view.products().stream().filter(p->"SALES_ORDER_ITEM".equals(p.sourceType()))
            .map(p->new PreviewItem("SALES_ORDER_ITEM",p.salesOrderItemId(),null,null,null,null,null,p.deliveryDate(),p.requestedQty())).toList(); }
    private static Map<UUID,BigDecimal> salesDemand(AnalysisView view) { return view.products().stream().filter(p->"SALES_ORDER_ITEM".equals(p.sourceType()))
            .collect(Collectors.toMap(ProductView::salesOrderItemId,ProductView::requestedQty)); }
    private UUID action(BatchResult batch) { return h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId()); }
    private static MaterialView material(AnalysisView view,UUID id) { return view.flatMaterials().stream().filter(row->row.materialLineId().equals(id)).findFirst().orElseThrow(); }
    private static MaterialView child(AnalysisView view,MaterialView parent,UUID goods) { return view.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.analysisLineId())
            &&parent.nodeKey().equals(row.parentNodeKey())&&row.goodsId().equals(goods)).findFirst().orElseThrow(); }
    private record ChildBaseline(UUID material,BigDecimal required,BigDecimal sourceRequired) { }
    private record Prepared(AggregateMaterialOrderEndToEndTest.Case c,UUID targetGoods,boolean aliases,List<UUID> originals,Map<UUID,BigDecimal> sourceQty,
                            List<UUID> parents,Map<UUID,ChildBaseline> children,Map<UUID,BigDecimal> salesDemand) { }
}
