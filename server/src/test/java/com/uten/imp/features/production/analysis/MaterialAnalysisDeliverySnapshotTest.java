package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.delivery.DeliveryBom;
import com.uten.imp.common.delivery.DeliveryFrontier;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MaterialAnalysisDeliverySnapshotTest {
    private final UUID sourceId = UUID.randomUUID();
    private final UUID rootGoods = UUID.randomUUID();
    private final UUID unit = UUID.randomUUID();

    @Test
    void skippedAssemblyDoesNotUseStockAndForwardsItsFullDesignQuantity() throws Exception {
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        var source = source(plan(List.of(List.of(parent))));
        var first = node(parent, null, "2", "200", true);
        var second = node(child, first, "3", "600", false);
        var projected = MaterialAnalysisDeliverySnapshot.project(source, List.of(first, second));
        assertThat(projected.getFirst().deliveryContext()).isTrue();
        assertThat(projected.getFirst().hardGate()).isFalse();
        assertThat(projected.getFirst().controlStage()).isEqualTo("REFERENCE");
        assertThat(projected.get(1).deliveryFrontier()).isTrue();
        var diagnosis = MaterialAnalysisService.allocateNestedDiagnostics(List.of(source), projected,
                Map.of(first.dimension(), new BigDecimal("9999"), second.dimension(), new BigDecimal("10")));
        var firstAllocation = diagnosis.nodeAllocations().get(sourceId + "|" + first.nodeKey());
        var secondAllocation = diagnosis.nodeAllocations().get(sourceId + "|" + second.nodeKey());
        assertThat(firstAllocation.allocatedQty()).isZero();
        assertThat(firstAllocation.shortageQty()).isZero();
        assertThat(secondAllocation.allocatedQty()).isEqualByComparingTo("10");
        assertThat(secondAllocation.shortageQty()).isEqualByComparingTo("590");
        assertThat(diagnosis.nodes().get(1).snapshotRequiredQty()).isEqualByComparingTo("600");
    }

    @Test
    void nestedSkippedAssemblyUsesEachEdgeExactlyOnceAndKeepsPaths() throws Exception {
        UUID a = UUID.randomUUID(), b = UUID.randomUUID(), c = UUID.randomUUID();
        var source = source(plan(List.of(List.of(a), List.of(a, b))));
        var first = node(a, null, "2", "200", true);
        var second = node(b, first, "3", "600", true);
        var third = node(c, second, "4", "2400", false);
        var projected = MaterialAnalysisDeliverySnapshot.project(source, List.of(first, second, third));
        assertThat(projected).extracting(MaterialAnalysisService.BomNode::deliveryContext)
                .containsExactly(true, true, false);
        assertThat(projected).extracting(MaterialAnalysisService.BomNode::deliveryFrontier)
                .containsExactly(false, false, true);
        var diagnosis = MaterialAnalysisService.allocateNestedDiagnostics(List.of(source), projected, Map.of());
        assertThat(diagnosis.nodes().get(2).snapshotRequiredQty()).isEqualByComparingTo("2400");
        assertThat(diagnosis.nodes().get(2).nodeKey()).isEqualTo(a + "/" + b + "/" + c);
        assertThat(diagnosis.nodeAllocations().get(sourceId + "|" + third.nodeKey()).shortageQty())
                .isEqualByComparingTo("2400");
    }

    @Test
    void wholeDeliveryBoundaryStillUsesExistingShortageDrivenManufacturingSubtree() throws Exception {
        UUID a = UUID.randomUUID(), b = UUID.randomUUID();
        var source = source(plan(List.of(List.of(a, b))));
        var first = node(a, null, "2", "200", true);
        var second = node(b, first, "3", "600", true);
        var projected = MaterialAnalysisDeliverySnapshot.project(source, List.of(first, second));
        assertThat(projected.getFirst().deliveryFrontier()).isTrue();
        assertThat(projected.get(1).deliveryContext()).isFalse();
        assertThat(projected.get(1).deliveryFrontier()).isFalse();
        var diagnosis = MaterialAnalysisService.allocateNestedDiagnostics(List.of(source), projected,
                Map.of(first.dimension(), new BigDecimal("175")));
        assertThat(diagnosis.nodes().get(1).snapshotRequiredQty()).isEqualByComparingTo("75");
    }

    @Test
    void customerFrontierDoesNotAdoptActualConsumptionButItsManufacturingChildrenDo() throws Exception {
        UUID a = UUID.randomUUID(), b = UUID.randomUUID();
        var source = source(plan(List.of()));
        var first = node(a, null, "2", "300", true);
        first = new MaterialAnalysisService.BomNode(first.analysisItemId(), first.bomItemId(), first.parentGoodsId(),
                first.goodsId(), first.colorId(), first.unitId(), first.depth(), first.nodeKey(), first.parentNodeKey(),
                first.parentPerProductQty(), new MaterialAnalysisService.BomUsage(new BigDecimal("2"),new BigDecimal("3"),"ACTUAL","test",1L,null),
                new BigDecimal("3"),new BigDecimal("300"), first.goodsCode(),first.goodsName(),first.spec(),first.colorName(),
                first.unitName(),first.safetyStock(),first.suggestion(),first.hasChildren(),first.controlStage(),
                first.consumptionBasis(),first.basisOutputQty(),first.allowPartialPackage(),first.hardGate(),List.of());
        var child = node(b, first, "4", "1200", false);
        var projected = MaterialAnalysisDeliverySnapshot.project(source, List.of(first, child));
        assertThat(projected.getFirst().snapshotRequiredQty()).isEqualByComparingTo("200");
        assertThat(projected.getFirst().bomQty()).isEqualByComparingTo("2");
        assertThat(projected.get(1).bomQty()).isEqualByComparingTo("4");
        assertThat(projected.get(1).perProductQty()).isEqualByComparingTo("8");
    }

    @Test
    void bomDeliveryProductCannotCreateFinishedProductPlanOrSurplus() throws Exception {
        var source = source(plan(List.of()));
        var view = source.toView(BigDecimal.ZERO, true, MaterialAnalysisService.ProductPlanState.NONE);
        assertThat(view.canSchedule()).isFalse();
        assertThat(view.canIssueSurplus()).isFalse();
        assertThat(view.scheduleBlockedReason()).contains("无需总装");
        assertThat(view.deliveryPlan().isBom()).isTrue();
        assertThat(view.rootMaterialLineId()).isNull();
    }

    @Test
    void bulkPackagingRemovesOnlyCustomerPackagingAndKeepsWholeBoundaryManufacturingConsumption() throws Exception {
        var plan = new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.BULK,
                List.of(),List.of(),"a".repeat(64));
        var source = source(new ObjectMapper().writeValueAsString(plan));
        var assembly = node(UUID.randomUUID(),null,"2","200",true);
        var internalPack = node(UUID.randomUUID(),assembly,"3","600",false);
        var customerPack = node(UUID.randomUUID(),null,"1","100",false);
        var recipeAssembly = recipe(assembly,DeliveryBom.MaterialRole.PART,
                List.of(recipe(internalPack,DeliveryBom.MaterialRole.PRODUCT_PACKAGING,List.of())));
        var root = new DeliveryBom.Node(List.of(),null,rootGoods,"ROOT","root",unit,"个",null,null,null,
                "自制","1","PER_UNIT","1",true,DeliveryBom.ChildrenState.LOADED,false,
                DeliveryBom.MaterialRole.PART,List.of(),List.of(recipeAssembly,
                        recipe(customerPack,DeliveryBom.MaterialRole.PRODUCT_PACKAGING,List.of())));
        var preview = DeliveryFrontier.resolve(new DeliveryBom.Snapshot(1,rootGoods,plan.bomFingerprint(),root),
                new BigDecimal("100"),plan);
        assertThat(preview.issues()).isEmpty();
        var projected = MaterialAnalysisDeliverySnapshot.project(source,List.of(assembly,internalPack,customerPack),preview);
        assertThat(projected.getFirst().deliveryFrontier()).isTrue();
        assertThat(projected.get(1).deliveryContext()).isFalse();
        assertThat(projected.get(1).snapshotRequiredQty()).isEqualByComparingTo("600");
        assertThat(projected.get(2).deliveryContext()).isTrue();
        assertThat(projected.get(2).snapshotRequiredQty()).isZero();
    }

    private DeliveryBom.Node recipe(MaterialAnalysisService.BomNode node,DeliveryBom.MaterialRole role,List<DeliveryBom.Node> children) {
        return new DeliveryBom.Node(java.util.Arrays.stream(node.nodeKey().split("/")).map(UUID::fromString).toList(),
                node.bomItemId(),node.goodsId(),node.goodsCode(),node.goodsName(),unit,"个",null,null,null,"自制",
                node.usage().designQty().toPlainString(),"PER_UNIT","1",true,
                children.isEmpty()?DeliveryBom.ChildrenState.NONE:DeliveryBom.ChildrenState.LOADED,false,role,List.of(),children);
    }

    @Test
    void legacyAssemblyKeepsOriginalPipelineAndSnapshotDefaults() {
        var source = source(null);
        var node = node(UUID.randomUUID(), null, "2", "200", false);
        var projected = MaterialAnalysisDeliverySnapshot.project(source, List.of(node));
        assertThat(projected).containsExactly(node);
        assertThat(source.bomDelivery()).isFalse();
        assertThat(MaterialAnalysisDeliverySnapshot.plan(null)).isEqualTo(DeliveryPlan.assembled());
    }

    @Test
    void missingEffectivePathFailsWithoutDroppingUnseenDemand() throws Exception {
        var source = source(plan(List.of(List.of(UUID.randomUUID()))));
        assertThatThrownBy(() -> MaterialAnalysisDeliverySnapshot.project(source,
                List.of(node(UUID.randomUUID(), null, "1", "100", false))))
                .isInstanceOf(ApiException.class).hasMessageContaining("路径已变化");
    }

    @Test
    void sourcePlanChangeCannotReplaceFrozenProductionFacts() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{sourceId, UUID.randomUUID()}));
        assertThatThrownBy(() -> MaterialAnalysisDeliverySnapshot.freeze(em, UUID.randomUUID()))
                .isInstanceOf(ApiException.class).hasMessageContaining("不能覆盖原快照");
    }

    private String plan(List<List<UUID>> paths) throws Exception {
        return new ObjectMapper().writeValueAsString(new DeliveryPlan(1, DeliveryPlan.Mode.BOM,
                DeliveryPlan.Packaging.ORIGINAL,
                paths.stream().map(p -> new DeliveryPlan.NodeMode(p, DeliveryPlan.NodeDelivery.CHILDREN)).toList(),
                List.of(), "a".repeat(64)));
    }

    private MaterialAnalysisService.SourceLine source(String plan) {
        Object[] row = new Object[54];
        row[0]=sourceId;row[1]="SALES_ORDER_ITEM";row[2]=UUID.randomUUID();row[3]=UUID.randomUUID();
        row[4]="XD-TEST";row[5]=LocalDate.of(2026,11,4);row[6]=LocalDate.of(2026,11,20);
        row[8]=rootGoods;row[9]="ROOT";row[10]="root";row[14]=unit;row[15]="个";
        row[16]=BigDecimal.ONE;row[17]=new BigDecimal("100");row[20]=new BigDecimal("100");
        row[28]=(short)1;row[35]=1;row[43]=true;row[53]=plan;
        return MaterialAnalysisService.SourceLine.from(row);
    }

    private MaterialAnalysisService.BomNode node(UUID edge,MaterialAnalysisService.BomNode parent,
            String use,String required,boolean hasChildren) {
        String path=parent==null?edge.toString():parent.nodeKey()+"/"+edge;
        return new MaterialAnalysisService.BomNode(sourceId,edge,parent==null?rootGoods:parent.goodsId(),
                UUID.randomUUID(),null,unit,parent==null?1:parent.depth()+1,path,parent==null?null:parent.nodeKey(),
                parent==null?BigDecimal.ONE:parent.perProductQty(),new BigDecimal(use),
                parent==null?new BigDecimal(use):parent.perProductQty().multiply(new BigDecimal(use)),
                new BigDecimal(required),edge.toString(),"component",null,null,"个",BigDecimal.ZERO,
                hasChildren?"MAKE":"BUY",hasChildren,"START","PER_UNIT",BigDecimal.ONE,true,true);
    }
}
