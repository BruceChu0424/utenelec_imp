package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ProductView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SupplyActionView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.DownstreamReference;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class AggregateMaterialOrderPreviewServiceTest {
    private static final UUID ANALYSIS=UUID.randomUUID(),WAREHOUSE=UUID.randomUUID(),GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static final String FINGERPRINT="a".repeat(64);
    private static final LocalDate DATE=LocalDate.of(2026,9,25);
    private static BigDecimal qty(String value){return new BigDecimal(value);}
    private static AggregateMaterialOrderPreviewService service() {
        var access=mock(ProductionDocumentAccessPolicy.class);when(access.hasAuthority(anyString())).thenReturn(true);
        return new AggregateMaterialOrderPreviewService(null,access,mock(AggregateMaterialBatchLookup.class));
    }
    private static MaterialView material(UUID source,String node,String remaining) {
        var value=mock(MaterialView.class);
        when(value.materialLineId()).thenReturn(UUID.randomUUID());when(value.analysisLineId()).thenReturn(source);
        when(value.nodeKey()).thenReturn(node);when(value.goodsId()).thenReturn(GOODS);when(value.unitId()).thenReturn(UNIT);
        when(value.sourceConfirmed()).thenReturn("MAKE");when(value.routeConfirmed()).thenReturn(true);
        when(value.actionable()).thenReturn(true);when(value.level()).thenReturn(1);when(value.requirementState()).thenReturn("ACTIVE");
        when(value.requiredQty()).thenReturn(qty("1000"));when(value.shortageQty()).thenReturn(qty("1000"));
        when(value.planningUncoveredQty()).thenReturn(qty(remaining));when(value.sourceRequiredQty()).thenReturn(qty("1000"));
        when(value.downstreamReferences()).thenReturn(List.of());when(value.path()).thenReturn(List.of("外壳","保护门"));
        when(value.goodsName()).thenReturn("黑色保护门");when(value.goodsCode()).thenReturn("V50052");when(value.unitName()).thenReturn("个");
        return value;
    }
    private static ProductView product(UUID id,String type,String ordered) {
        var value=mock(ProductView.class);when(value.analysisLineId()).thenReturn(id);when(value.sourceType()).thenReturn(type);
        when(value.allocationPriority()).thenReturn(1);when(value.deliveryDate()).thenReturn(DATE);
        when(value.unitRate()).thenReturn(BigDecimal.ONE);when(value.issuedPlanQty()).thenReturn(qty(ordered));
        when(value.goodsName()).thenReturn("原产品");return value;
    }
    private static AnalysisView view(List<ProductView> products,List<MaterialView> materials) {
        return view(products,materials,List.of());
    }
    private static AnalysisView view(List<ProductView> products,List<MaterialView> materials,List<SupplyActionView> actions) {
        return new AnalysisView(ANALYSIS,"PARTIALLY_PLANNED",13,FINGERPRINT,FINGERPRINT,WAREHOUSE,List.of(WAREHOUSE),null,
                products,materials,List.of(),actions,List.of(),false,null,Map.of(),0,Map.of(GOODS,qty("0.1")),null);
    }
    private static GroupInput group(List<MaterialView> materials,String quantity,boolean extra) {
        return new GroupInput("material-group",materials.stream().map(MaterialView::materialLineId).toList(),"MAKE",qty(quantity),extra,
                UUID.fromString("00000000-0000-0000-0000-000000000100"),UUID.fromString("00000000-0000-0000-0000-000000000200"),null,null,null,null,null,null);
    }
    private static PreviewRequest request(List<GroupInput> groups) {
        return new PreviewRequest(13L,FINGERPRINT,"aggregate-preview-key",WAREHOUSE,DATE,DATE,true,groups);
    }

    @Test void threeExistingManufacturingPlansDisplay3000OrderedAndNoRemainingOrderDespitePhysicalShortage() {
        List<ProductView> products=new ArrayList<>();List<MaterialView> members=new ArrayList<>();
        for(int i=0;i<3;i++) {
            UUID source=UUID.randomUUID(),anchor=UUID.randomUUID();
            MaterialView member=material(source,"source-"+i,"0");when(member.planAnchorAnalysisLineId()).thenReturn(anchor);
            members.add(member);products.add(product(source,"SALES","0"));products.add(product(anchor,"MAKE_COMPONENT","1000"));
        }
        Preview result=service().resolve(ANALYSIS,request(List.of(group(members,"0",false))),view(products,members));
        assertThat(result.groups().getFirst().orderedQty()).isEqualByComparingTo("3000");
        assertThat(result.groups().getFirst().remainingQty()).isZero();
        assertThat(result.groups().getFirst().sourceRequiredQty()).isEqualByComparingTo("3000");
        assertThat(result.groups().getFirst().blockedReason()).isNull();
    }

    @Test void reviewContainsAllSourcesAndPublicQuantityHasNoInventedProductOwner() {
        List<MaterialView> members=List.of(material(UUID.randomUUID(),"a","1000"),material(UUID.randomUUID(),"b","1000"),material(UUID.randomUUID(),"c","1000"));
        AnalysisView view=view(members.stream().map(m->product(m.analysisLineId(),"SALES","0")).toList(),members);
        GroupPreview result=service().resolve(ANALYSIS,request(List.of(group(members,"3100",true))),view).groups().getFirst();
        assertThat(result.sources()).hasSize(3);
        assertThat(result.sources().stream().map(SourcePreview::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("3000");
        assertThat(result.publicExtraQty()).isEqualByComparingTo("100");
        assertThat(result.allowedOverproductionRate()).isEqualByComparingTo("0.1");
        assertThat(result.blockedReason()).isNull();
    }

    @Test void aSharedPhysicalBatchRoundsOnePackageInsteadOfOneForEachProduct() {
        List<MaterialView> members=new ArrayList<>(),all=new ArrayList<>();List<ProductView> products=new ArrayList<>();
        UUID inputGoods=UUID.randomUUID();
        for(int i=0;i<3;i++) {
            UUID source=UUID.randomUUID();MaterialView member=material(source,"p"+i,"1");members.add(member);all.add(member);
            products.add(product(source,"SALES","0"));
            MaterialView child=material(source,"p"+i+"/same-bom-edge","1");
            when(child.parentNodeKey()).thenReturn("p"+i);when(child.goodsId()).thenReturn(inputGoods);when(child.level()).thenReturn(2);
            when(child.controlStage()).thenReturn("START");when(child.consumptionBasis()).thenReturn("PER_PACKAGE");
            when(child.bomQty()).thenReturn(BigDecimal.ONE);when(child.basisOutputQty()).thenReturn(qty("5"));when(child.allowPartialPackage()).thenReturn(false);
            all.add(child);
        }
        GroupPreview result=service().resolve(ANALYSIS,request(List.of(group(members,"3",false))),view(products,all)).groups().getFirst();
        assertThat(result.blockedReason()).isNull();assertThat(result.sharedBomChildren()).hasSize(1);
        assertThat(result.sharedBomChildren().getFirst().requiredQty()).isEqualByComparingTo("1");
    }

    @Test void aChangedTotalOrSupplyCapacityInvalidatesTheReviewedFingerprint() {
        MaterialView member=material(UUID.randomUUID(),"a","1000");
        AnalysisView view=view(List.of(product(member.analysisLineId(),"SALES","0")),List.of(member));
        var request=request(List.of(group(List.of(member),"600",false)));
        String before=service().resolve(ANALYSIS,request,view).previewFingerprint();
        when(member.planningUncoveredQty()).thenReturn(qty("900"));
        assertThat(service().resolve(ANALYSIS,request,view).previewFingerprint()).isNotEqualTo(before);
        assertThat(service().resolve(ANALYSIS,request(List.of(group(List.of(member),"601",false))),view).previewFingerprint()).isNotEqualTo(before);
    }

    @Test void overlappingScopesAndDifferentMaterialIdentitiesAreRejected() {
        MaterialView first=material(UUID.randomUUID(),"a","1000"),second=material(UUID.randomUUID(),"b","1000");
        AnalysisView view=view(List.of(),List.of(first,second));
        GroupInput duplicate=group(List.of(first,first),"100",false);
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(duplicate)),view)).isInstanceOf(ApiException.class);
        when(second.colorId()).thenReturn(UUID.randomUUID());
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(group(List.of(first,second),"100",false))),view)).isInstanceOf(ApiException.class);
    }

    @Test void rootProductCannotBeRecastAsAComponentAndLoseItsSalesSource() {
        MaterialView root=material(UUID.randomUUID(),"root","1000");
        when(root.level()).thenReturn(0);
        AnalysisView current=view(List.of(product(root.analysisLineId(),"SALES","0")),List.of(root));
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(group(List.of(root),"1000",false))),current))
                .isInstanceOf(ApiException.class).hasMessageContaining("顶层产品请按产品办理");
    }

    @Test void separateClientKeysCannotSplitTheSamePhysicalBatchWithinOneReviewedCommand() {
        MaterialView first=material(UUID.randomUUID(),"first","1000"),second=material(UUID.randomUUID(),"second","1000");
        GroupInput one=group(List.of(first),"100",false),two=group(List.of(second),"200",false);
        GroupInput renamed=new GroupInput("another-key",two.materialLineIds(),two.route(),two.qty(),two.allowPublicExtra(),two.departmentId(),two.workerId(),two.teamDepartmentId(),two.billDate(),two.deliveryDate(),two.productNo(),two.allowedOverproductionRate(),two.safetyQty());
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(one,renamed)),view(List.of(),List.of(first,second))))
                .isInstanceOf(ApiException.class).hasMessageContaining("只能提交一组");
    }

    @Test void sharedBatchCountsPrivateSharesAndPublicOutputOnceAcrossAllThreeSources() {
        SupplyActionView action=sharedAction("3000","100");
        List<MaterialView> members=new ArrayList<>();
        for(int i=0;i<3;i++) {
            MaterialView member=material(UUID.randomUUID(),"source"+i,"0");
            DownstreamReference ref=reference(action,"1000");
            when(member.downstreamReferences()).thenReturn(List.of(ref));
            members.add(member);
        }
        GroupPreview shown=service().resolve(ANALYSIS,request(List.of(group(members,"0",false))),view(List.of(),members,List.of(action))).groups().getFirst();
        assertThat(shown.orderedQty()).isEqualByComparingTo("3100");
        assertThat(shown.sources()).allSatisfy(source->assertThat(source.orderedQty()).isEqualByComparingTo("1000"));
        GroupPreview subset=service().resolve(ANALYSIS,request(List.of(group(members.subList(0,2),"0",false))),view(List.of(),members,List.of(action))).groups().getFirst();
        assertThat(subset.orderedQty()).isEqualByComparingTo("2000");
    }

    @Test void purePublicHistoryRemainsVisibleWithoutInventingAPrivateAllocation() {
        SupplyActionView action=sharedAction("0","12");
        MaterialView member=material(UUID.randomUUID(),"source","0");
        DownstreamReference ref=reference(action,"0");
        when(member.downstreamReferences()).thenReturn(List.of(ref));
        GroupPreview shown=service().resolve(ANALYSIS,request(List.of(group(List.of(member),"0",false))),view(List.of(),List.of(member),List.of(action))).groups().getFirst();
        assertThat(shown.orderedQty()).isEqualByComparingTo("12");
        assertThat(shown.sources().getFirst().orderedQty()).isZero();
        assertThat(shown.sources().getFirst().allocatedQty()).isZero();
    }

    @Test void legacyPublicQuantityIsRoundedAfterTheSelectedSourceSharesAreCombined() {
        SupplyActionView action=sharedAction("3","1");when(action.operationType()).thenReturn("SUPPLY");
        List<MaterialView> members=new ArrayList<>();
        for(int i=0;i<3;i++) {
            MaterialView member=material(UUID.randomUUID(),"source"+i,"0");
            DownstreamReference ref=reference(action,"1");when(member.downstreamReferences()).thenReturn(List.of(ref));members.add(member);
        }
        GroupPreview shown=service().resolve(ANALYSIS,request(List.of(group(members,"0",false))),view(List.of(),members,List.of(action))).groups().getFirst();
        assertThat(shown.orderedQty()).isEqualByComparingTo("4");
        GroupPreview subset=service().resolve(ANALYSIS,request(List.of(group(members.subList(0,2),"0",false))),view(List.of(),members,List.of(action))).groups().getFirst();
        assertThat(subset.orderedQty()).isEqualByComparingTo("2.6667");
    }

    @Test void aSharedAppendKeepsEarlierIndependentManufacturingPlanInOrderedTotal() {
        SupplyActionView action=sharedAction("500","0");UUID anchor=UUID.randomUUID();
        MaterialView member=material(UUID.randomUUID(),"source","0");
        when(member.planAnchorAnalysisLineId()).thenReturn(anchor);
        DownstreamReference ref=reference(action,"500");
        when(member.downstreamReferences()).thenReturn(List.of(ref));
        GroupPreview shown=service().resolve(ANALYSIS,request(List.of(group(List.of(member),"0",false))),view(List.of(product(anchor,"MAKE_COMPONENT","1000")),List.of(member),List.of(action))).groups().getFirst();
        assertThat(shown.orderedQty()).isEqualByComparingTo("1500");
    }

    @Test void notifyingTheNextSubcontractStepDoesNotOrderTheSameSharedQuantityAgain() {
        SupplyActionView original=sharedAction("3","1"),continuation=sharedAction("3","1");
        when(continuation.operationType()).thenReturn("AGGREGATE_CONTINUATION");
        MaterialView member=material(UUID.randomUUID(),"source","0");
        DownstreamReference first=reference(original,"3"),next=reference(continuation,"3");
        when(member.downstreamReferences()).thenReturn(List.of(first,next));
        GroupPreview shown=service().resolve(ANALYSIS,request(List.of(group(List.of(member),"0",false))),view(List.of(),List.of(member),List.of(original,continuation))).groups().getFirst();
        assertThat(shown.orderedQty()).isEqualByComparingTo("4");
        assertThat(shown.sources().getFirst().orderedQty()).isEqualByComparingTo("3");
    }

    private static SupplyActionView sharedAction(String privateQty,String publicQty) {
        SupplyActionView action=mock(SupplyActionView.class);
        when(action.actionId()).thenReturn(UUID.randomUUID());when(action.operationType()).thenReturn("AGGREGATE_SUPPLY");
        when(action.requestedQty()).thenReturn(qty(privateQty));when(action.publicSurplusQty()).thenReturn(qty(publicQty));
        return action;
    }
    private static DownstreamReference reference(SupplyActionView action,String amount) {
        DownstreamReference reference=mock(DownstreamReference.class);UUID actionId=action.actionId();
        when(reference.actionId()).thenReturn(actionId);when(reference.allocatedQty()).thenReturn(qty(amount));
        when(reference.route()).thenReturn("MAKE");when(reference.status()).thenReturn("ACTIVE");
        return reference;
    }

    @Test void originalDeepPathResolvesAllExactTargetsAndDeduplicatesTheSamePhysicalRow() {
        MaterialView original=material(UUID.randomUUID(),"original/deep","0"),otherOriginal=material(UUID.randomUUID(),"other/deep","0");
        MaterialView first=material(UUID.randomUUID(),"canonical-one","3"),second=material(UUID.randomUUID(),"canonical-two","2");
        List<UUID> exactTargets=List.of(first.materialLineId(),second.materialLineId());
        for(MaterialView source:List.of(original,otherOriginal)) {
            when(source.requiredQty()).thenReturn(BigDecimal.ZERO);
            when(source.aggregatePreparation()).thenReturn(new MaterialAnalysisContracts.AggregatePreparationView(qty("5"),BigDecimal.ZERO,
                    BigDecimal.ZERO,BigDecimal.ZERO,false,qty("5"),qty("5"),exactTargets,true));
        }
        var result=service().resolve(ANALYSIS,request(List.of(group(List.of(original,otherOriginal),"5",false))),
                view(List.of(),List.of(original,otherOriginal,first,second))).groups().getFirst();
        assertThat(result.sources()).hasSize(2);
        assertThat(result.sources()).extracting(SourcePreview::materialLineId).containsExactlyInAnyOrder(first.materialLineId(),second.materialLineId());
        assertThat(result.sources().stream().map(SourcePreview::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("5");
    }

    @Test void anOriginalSourceBlockCannotBeBypassedByItsHealthyCanonicalTarget() {
        MaterialView original=material(UUID.randomUUID(),"original/blocked","0"),target=material(UUID.randomUUID(),"canonical/open","1");
        UUID targetId=target.materialLineId(),originalItem=original.analysisLineId();
        when(original.requiredQty()).thenReturn(BigDecimal.ZERO);
        when(original.aggregatePreparation()).thenReturn(new MaterialAnalysisContracts.AggregatePreparationView(qty("1"),BigDecimal.ZERO,BigDecimal.ZERO,
                BigDecimal.ZERO,false,qty("1"),qty("1"),List.of(targetId),true));
        AnalysisView current=new AnalysisView(ANALYSIS,"PARTIALLY_PLANNED",13,FINGERPRINT,FINGERPRINT,WAREHOUSE,List.of(WAREHOUSE),null,
                List.of(),List.of(original,target),List.of(),List.of(),List.of(),false,null,
                Map.of(originalItem,"原销售来源已停止"),0,Map.of(GOODS,qty("0.1")),null);
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(group(List.of(original),"1",false))),current))
                .isInstanceOf(ApiException.class).hasMessageContaining("原销售来源已停止");
    }

    @Test void originalRequestedQuantitiesBoundEachOfSeveralCanonicalTargets() {
        MaterialView a=material(UUID.randomUUID(),"original/a","0"),b=material(UUID.randomUUID(),"original/b","0");
        MaterialView first=material(UUID.randomUUID(),"canonical/one","3000"),second=material(UUID.randomUUID(),"canonical/two","1000");
        UUID firstId=first.materialLineId(),secondId=second.materialLineId();
        when(a.requiredQty()).thenReturn(BigDecimal.ZERO);when(b.requiredQty()).thenReturn(BigDecimal.ZERO);
        when(a.aggregatePreparation()).thenReturn(new MaterialAnalysisContracts.AggregatePreparationView(qty("500"),BigDecimal.ZERO,BigDecimal.ZERO,
                BigDecimal.ZERO,false,qty("500"),qty("500"),List.of(firstId),true));
        when(b.aggregatePreparation()).thenReturn(new MaterialAnalysisContracts.AggregatePreparationView(qty("500"),BigDecimal.ZERO,BigDecimal.ZERO,
                BigDecimal.ZERO,false,qty("500"),qty("500"),List.of(secondId),true));
        var base=group(List.of(a,b),"1000",false);
        var input=new GroupInput(base.clientGroupKey(),base.materialLineIds(),base.route(),base.qty(),false,base.departmentId(),base.workerId(),
                base.teamDepartmentId(),base.billDate(),base.deliveryDate(),base.productNo(),base.allowedOverproductionRate(),base.safetyQty(),
                Map.of(a.materialLineId(),qty("500"),b.materialLineId(),qty("500")));
        var result=service().resolve(ANALYSIS,request(List.of(input)),view(List.of(),List.of(a,b,first,second))).groups().getFirst();
        assertThat(result.blockedReason()).isNull();assertThat(result.publicExtraQty()).isZero();
        assertThat(result.sources()).hasSize(2).allSatisfy(source->assertThat(source.allocatedQty()).isEqualByComparingTo("500"));
    }

    @Test void sourceQuantityIntentMustBeCompleteConservedAndPartOfTheReviewFingerprint() {
        MaterialView first=material(UUID.randomUUID(),"one","1000"),second=material(UUID.randomUUID(),"two","1000");
        var base=group(List.of(first,second),"11000",true);
        java.util.function.Function<Map<UUID,BigDecimal>,GroupInput> intent=map->new GroupInput(base.clientGroupKey(),base.materialLineIds(),base.route(),base.qty(),
                base.allowPublicExtra(),base.departmentId(),base.workerId(),base.teamDepartmentId(),base.billDate(),base.deliveryDate(),base.productNo(),base.allowedOverproductionRate(),base.safetyQty(),map);
        AnalysisView current=view(List.of(),List.of(first,second));
        var original=service().resolve(ANALYSIS,request(List.of(intent.apply(Map.of(first.materialLineId(),qty("10000"),second.materialLineId(),qty("1000"))))),current);
        var swapped=service().resolve(ANALYSIS,request(List.of(intent.apply(Map.of(first.materialLineId(),qty("1000"),second.materialLineId(),qty("10000"))))),current);
        assertThat(swapped.previewFingerprint()).isNotEqualTo(original.previewFingerprint());
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(intent.apply(Map.of(first.materialLineId(),qty("11000"))))),current))
                .isInstanceOf(ApiException.class).hasMessageContaining("完整对应");
        assertThatThrownBy(()->service().resolve(ANALYSIS,request(List.of(intent.apply(Map.of(first.materialLineId(),qty("10000"),second.materialLineId(),qty("2"))))),current))
                .isInstanceOf(ApiException.class).hasMessageContaining("总量");
    }

    @Test void manufacturingPublicAdoptionReducesOnlyNewProductionAndItsChildRequirement() {
        MaterialView parent=material(UUID.randomUUID(),"parent","3"),child=material(parent.analysisLineId(),"parent/edge","6");
        when(child.parentNodeKey()).thenReturn("parent");when(child.goodsId()).thenReturn(UUID.randomUUID());when(child.level()).thenReturn(2);
        when(child.controlStage()).thenReturn("START");when(child.consumptionBasis()).thenReturn("PER_UNIT");
        when(child.bomQty()).thenReturn(qty("2"));when(child.basisOutputQty()).thenReturn(BigDecimal.ONE);when(child.allowPartialPackage()).thenReturn(true);
        var candidate=new PreplanMakePublicSupplyService.Candidate(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),"SJ-other",qty("2"),DATE,false,true);
        when(parent.makePublicSupplyRefs()).thenReturn(List.of(candidate));
        var result=service().resolve(ANALYSIS,request(List.of(group(List.of(parent),"3",false))),view(List.of(),List.of(parent,child))).groups().getFirst();
        assertThat(result.requestedQty()).isEqualByComparingTo("3");
        assertThat(result.sharedBomChildren().getFirst().requiredQty()).isEqualByComparingTo("2");
    }

    @Test void purchasePublicAdoptionAlsoReducesManufacturingAndItsChildRequirement() {
        MaterialView parent=material(UUID.randomUUID(),"parent","3"),child=material(parent.analysisLineId(),"parent/edge","6");
        when(child.parentNodeKey()).thenReturn("parent");when(child.goodsId()).thenReturn(UUID.randomUUID());when(child.level()).thenReturn(2);
        when(child.controlStage()).thenReturn("START");when(child.consumptionBasis()).thenReturn("PER_UNIT");
        when(child.bomQty()).thenReturn(qty("2"));when(child.basisOutputQty()).thenReturn(BigDecimal.ONE);when(child.allowPartialPackage()).thenReturn(true);
        var candidate=new MaterialAnalysisContracts.SharedFutureSupplyRef("BUY",qty("2"),qty("2"),DATE,UUID.randomUUID(),"PURCHASE_REQUEST",UUID.randomUUID(),"CS-other",false);
        when(parent.sharedFutureSupplyRefs()).thenReturn(List.of(candidate));
        var result=service().resolve(ANALYSIS,request(List.of(group(List.of(parent),"3",false))),view(List.of(),List.of(parent,child))).groups().getFirst();
        assertThat(result.requestedQty()).isEqualByComparingTo("3");
        assertThat(result.sharedBomChildren().getFirst().requiredQty()).isEqualByComparingTo("2");
    }

    @Test void hiddenSourceDocumentsStillForecastTheirPublicBudgetWithoutExposingIds() {
        MaterialView parent=material(UUID.randomUUID(),"parent","3"),child=material(parent.analysisLineId(),"parent/edge","6");
        when(child.parentNodeKey()).thenReturn("parent");when(child.goodsId()).thenReturn(UUID.randomUUID());when(child.level()).thenReturn(2);
        when(child.controlStage()).thenReturn("START");when(child.consumptionBasis()).thenReturn("PER_UNIT");
        when(child.bomQty()).thenReturn(qty("2"));when(child.basisOutputQty()).thenReturn(BigDecimal.ONE);when(child.allowPartialPackage()).thenReturn(true);
        var candidate=new MaterialAnalysisContracts.SharedFutureSupplyRef("BUY",qty("2"),qty("2"),DATE,null,null,null,null,false,"opaque-public-budget");
        when(parent.sharedFutureSupplyRefs()).thenReturn(List.of(candidate));
        var result=service().resolve(ANALYSIS,request(List.of(group(List.of(parent),"3",false))),view(List.of(),List.of(parent,child))).groups().getFirst();
        assertThat(result.requestedQty()).isEqualByComparingTo("3");
        assertThat(result.sharedBomChildren().getFirst().requiredQty()).isEqualByComparingTo("2");
    }

    @Test void singletonPrioritySupplementUsesItsExactNetResponsibilityInsteadOfPublicOverproduction() {
        MaterialView row=material(UUID.randomUUID(),"priority","0");UUID anchor=UUID.randomUUID();
        when(row.requiredQty()).thenReturn(BigDecimal.ZERO);when(row.actionable()).thenReturn(false);when(row.requirementState()).thenReturn("INACTIVE");
        when(row.priorityMakeSupplementQty()).thenReturn(qty("2"));when(row.planAnchorAnalysisLineId()).thenReturn(anchor);
        ProductView child=product(anchor,"MAKE_COMPONENT","10");when(child.remainingQty()).thenReturn(BigDecimal.ZERO);
        GroupPreview result=service().resolve(ANALYSIS,request(List.of(group(List.of(row),"2",false))),view(List.of(child),List.of(row))).groups().getFirst();
        assertThat(result.blockedReason()).isNull();assertThat(result.publicExtraQty()).isZero();assertThat(result.remainingQty()).isEqualByComparingTo("2");
        when(row.priorityMakeSupplementQty()).thenReturn(BigDecimal.ZERO);when(child.remainingQty()).thenReturn(qty("2"));
        result=service().resolve(ANALYSIS,request(List.of(group(List.of(row),"2",false))),view(List.of(child),List.of(row))).groups().getFirst();
        assertThat(result.blockedReason()).isNull();assertThat(result.publicExtraQty()).isZero();assertThat(result.remainingQty()).isEqualByComparingTo("2");
    }

    @Test void safetyReplenishmentIsASeparateBuySliceBoundedByTheLiveMainWarehouseGap() {
        MaterialView row=material(UUID.randomUUID(),"safety","0");when(row.sourceConfirmed()).thenReturn("BUY");
        when(row.mainWarehouseSafetyReplenishmentGapQty()).thenReturn(qty("6"));
        GroupInput input=new GroupInput("safety",List.of(row.materialLineId()),"BUY",BigDecimal.ZERO,false,null,null,null,null,null,null,null,qty("6"));
        GroupPreview result=service().resolve(ANALYSIS,request(List.of(input)),view(List.of(),List.of(row))).groups().getFirst();
        assertThat(result.blockedReason()).isNull();assertThat(result.requestedQty()).isZero();assertThat(result.safetyQty()).isEqualByComparingTo("6");
        when(row.mainWarehouseSafetyReplenishmentGapQty()).thenReturn(qty("5"));
        assertThat(service().resolve(ANALYSIS,request(List.of(input)),view(List.of(),List.of(row))).groups().getFirst().blockedReason()).contains("主仓缺口");
    }
}
