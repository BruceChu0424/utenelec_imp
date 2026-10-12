package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AggregateExternalBatchingTest {
    private final UUID source=UUID.randomUUID();

    private MaterialView material(String node,String parent) {
        MaterialView row=mock(MaterialView.class);
        when(row.materialLineId()).thenReturn(UUID.randomUUID());when(row.analysisLineId()).thenReturn(source);
        when(row.goodsId()).thenReturn(UUID.randomUUID());when(row.unitId()).thenReturn(UUID.randomUUID());
        when(row.nodeKey()).thenReturn(node);when(row.parentNodeKey()).thenReturn(parent);
        when(row.downstreamReferences()).thenReturn(List.of());
        return row;
    }

    private GroupPreview group(MaterialView row,String route) {
        GroupPreview group=mock(GroupPreview.class);
        UUID id=row.materialLineId(),goods=row.goodsId(),color=row.colorId();
        when(group.clientGroupKey()).thenReturn(id.toString());when(group.route()).thenReturn(route);
        when(group.goodsId()).thenReturn(goods);when(group.colorId()).thenReturn(color);
        when(group.safetyQty()).thenReturn(BigDecimal.ZERO);
        when(group.sources()).thenReturn(List.of(new SourcePreview(id,source,"来源",1,null,
                BigDecimal.TEN,BigDecimal.TEN,BigDecimal.TEN,BigDecimal.ZERO)));
        return group;
    }

    private List<GroupPreview> prefix(List<GroupPreview> groups,List<MaterialView> rows,List<SupplyActionView> actions) {
        AnalysisView view=mock(AnalysisView.class);when(view.flatMaterials()).thenReturn(rows);when(view.supplyActions()).thenReturn(actions);
        Map<String,GroupInput> inputs=new HashMap<>();
        for(GroupPreview group:groups)inputs.put(group.clientGroupKey(),new GroupInput(group.clientGroupKey(),
                List.of(UUID.fromString(group.clientGroupKey())),group.route(),BigDecimal.TEN,false,null,null,null,null,null,null,null,BigDecimal.ZERO));
        return AggregateMaterialOrderWriteService.independentExternalPrefix(groups,inputs,view);
    }

    @Test void differentExternalSiblingDimensionsCanShareOneSnapshot() {
        MaterialView first=material("first",null),second=material("second",null);
        List<GroupPreview> groups=List.of(group(first,"BUY"),group(second,"SUBCONTRACT"));
        assertEquals(groups,prefix(groups,List.of(first,second),List.of()));
    }

    @Test void selectedAncestorAndDescendantRemainSequentialInEitherOrder() {
        MaterialView first=material("parent",null),second=material("child","parent");
        GroupPreview parent=group(first,"SUBCONTRACT"),child=group(second,"BUY");
        assertEquals(List.of(parent),prefix(List.of(parent,child),List.of(first,second),List.of()));
        assertEquals(List.of(child),prefix(List.of(child,parent),List.of(first,second),List.of()));
    }

    @Test void differentUnitsCannotHideTheSamePhysicalStockDimension() {
        MaterialView first=material("first",null),second=material("second",null);
        UUID goods=first.goodsId();when(second.goodsId()).thenReturn(goods);
        GroupPreview a=group(first,"BUY"),b=group(second,"BUY");
        assertEquals(List.of(a),prefix(List.of(a,b),List.of(first,second),List.of()));
    }

    @Test void remappedAliasDoesNotReuseOriginalsSnapshot() {
        MaterialView original=material("original",null),target=material("target",null);
        GroupPreview group=group(target,"BUY");String key=original.materialLineId().toString();when(group.clientGroupKey()).thenReturn(key);
        assertEquals(List.of(),prefix(List.of(group),List.of(original,target),List.of()));
    }

    @Test void adoptablePublicSupplyRequiresTheSequentialClaimPath() {
        MaterialView row=material("material",null);GroupPreview group=group(row,"BUY");
        SharedFutureSupplyRef candidate=mock(SharedFutureSupplyRef.class);when(candidate.availableToClaimQty()).thenReturn(BigDecimal.ONE);
        when(row.sharedFutureSupplyRefs()).thenReturn(List.of(candidate));
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of()));
        when(row.sharedFutureSupplyRefs()).thenReturn(List.of());
        var make=mock(PreplanMakePublicSupplyService.Candidate.class);when(make.adoptable()).thenReturn(true);when(make.availableQty()).thenReturn(BigDecimal.ONE);
        when(row.makePublicSupplyRefs()).thenReturn(List.of(make));
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of()));
    }

    @Test void legacyDocumentAndSafetyReplenishmentRetainTheirOriginalPaths() {
        MaterialView row=material("material",null);GroupPreview group=group(row,"BUY");
        UUID id=UUID.randomUUID();SupplyActionView action=mock(SupplyActionView.class);
        when(action.actionId()).thenReturn(id);when(action.operationType()).thenReturn("SUPPLY");
        DownstreamReference ref=mock(DownstreamReference.class);when(ref.actionId()).thenReturn(id);when(ref.status()).thenReturn("CREATED");
        when(row.downstreamReferences()).thenReturn(List.of(ref));
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of(action)));
        when(row.downstreamReferences()).thenReturn(List.of());when(group.safetyQty()).thenReturn(BigDecimal.ONE);
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of()));
    }

    @Test void provenAliasesCanBatchWhileTheirOriginalAndTargetAncestryRemainIndependent() {
        MaterialView original=material("original",null),target=material("target",null),sibling=material("sibling",null);
        UUID originalId=original.materialLineId(),targetId=target.materialLineId();
        when(original.aggregatePreparation()).thenReturn(new AggregatePreparationView(BigDecimal.TEN,BigDecimal.ZERO,BigDecimal.ZERO,
                BigDecimal.ZERO,true,BigDecimal.TEN,BigDecimal.TEN,List.of(targetId),true));
        GroupPreview alias=group(target,"BUY"),other=group(sibling,"BUY");
        when(alias.clientGroupKey()).thenReturn(originalId.toString());
        when(alias.sources()).thenReturn(List.of(new SourcePreview(targetId,source,"来源",1,null,BigDecimal.TEN,BigDecimal.TEN,
                BigDecimal.TEN,BigDecimal.ZERO,List.of(originalId))));
        List<GroupPreview> groups=List.of(alias,other);
        assertEquals(groups,prefix(groups,List.of(original,target,sibling),List.of()));
        when(sibling.parentNodeKey()).thenReturn("target");
        assertEquals(List.of(alias),prefix(groups,List.of(original,target,sibling),List.of()));
        assertEquals(List.of(other),prefix(List.of(other,alias),List.of(original,target,sibling),List.of()));
    }

    @Test void ancestryAcrossSharedMakeOwnershipStillPreventsBatching() {
        MaterialView ancestor=material("external-parent",null),member=material("make-member","external-parent");
        MaterialView sharedRoot=material("shared-root",null),child=material("child","shared-root");
        UUID sharedSource=UUID.randomUUID();when(member.planAnchorAnalysisLineId()).thenReturn(sharedSource);
        when(sharedRoot.analysisLineId()).thenReturn(sharedSource);when(child.analysisLineId()).thenReturn(sharedSource);
        GroupPreview parent=group(ancestor,"SUBCONTRACT"),leaf=group(child,"BUY");
        List<MaterialView> rows=List.of(ancestor,member,sharedRoot,child);
        assertEquals(List.of(parent),prefix(List.of(parent,leaf),rows,List.of()));
        assertEquals(List.of(leaf),prefix(List.of(leaf,parent),rows,List.of()));
    }

    @Test void incompleteOrCyclicAncestryCannotProveIndependence() {
        MaterialView row=material("child","missing");GroupPreview group=group(row,"BUY");
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of()));
        when(row.parentNodeKey()).thenReturn("child");
        assertEquals(List.of(),prefix(List.of(group),List.of(row),List.of()));
    }

    @Test void everyOriginalIncludingZeroQuantityMustRetainItsSourceProof() {
        MaterialView first=material("first",null),zero=material("zero",null);
        UUID firstId=first.materialLineId(),zeroId=zero.materialLineId();GroupPreview group=group(first,"BUY");
        AnalysisView view=mock(AnalysisView.class);when(view.flatMaterials()).thenReturn(List.of(first,zero));
        GroupInput input=new GroupInput(group.clientGroupKey(),List.of(firstId,zeroId),"BUY",BigDecimal.TEN,false,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(firstId,BigDecimal.TEN,zeroId,BigDecimal.ZERO));
        Map<String,GroupInput> inputs=Map.of(group.clientGroupKey(),input);
        assertEquals(List.of(),AggregateExternalOrderCohort.prefix(List.of(group),inputs,view));
        List<SourcePreview> proof=List.of(group.sources().getFirst(),new SourcePreview(zeroId,source,"零量原行",2,null,
                BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO));
        when(group.sources()).thenReturn(proof);
        assertEquals(List.of(group),AggregateExternalOrderCohort.prefix(List.of(group),inputs,view));
    }

    @Test void descendantDemandCanAffectTheSamePhysicalMaterialOnAnotherSource() {
        MaterialView parent=material("parent",null),raw=material("raw","parent"),otherSourceRaw=material("other-raw",null);
        UUID rawGoods=raw.goodsId();when(otherSourceRaw.goodsId()).thenReturn(rawGoods);
        GroupPreview makeOutside=group(parent,"SUBCONTRACT"),buyRaw=group(otherSourceRaw,"BUY");
        List<MaterialView> rows=List.of(parent,raw,otherSourceRaw);
        assertEquals(List.of(makeOutside),prefix(List.of(makeOutside,buyRaw),rows,List.of()));
        assertEquals(List.of(buyRaw),prefix(List.of(buyRaw,makeOutside),rows,List.of()));

        // Sharing a downstream raw material does not make the two parent order
        // quantities dependent when that raw material is not itself selected.
        MaterialView sibling=material("sibling",null);when(otherSourceRaw.parentNodeKey()).thenReturn("sibling");
        GroupPreview otherOutside=group(sibling,"SUBCONTRACT");
        List<GroupPreview> parents=List.of(makeOutside,otherOutside);
        assertEquals(parents,prefix(parents,List.of(parent,raw,sibling,otherSourceRaw),List.of()));
    }

    @Test void activeBorrowInAffectedDescendantsRequiresSequentialRecalculationEvenWhenCurrentlyZero() {
        MaterialView parent=material("parent",null),child=material("child","parent");GroupPreview group=group(parent,"SUBCONTRACT");
        BorrowRef borrow=mock(BorrowRef.class);
        when(child.borrowedInQty()).thenReturn(BigDecimal.ZERO);when(child.borrowedOutQty()).thenReturn(BigDecimal.ZERO);
        when(child.borrowRefs()).thenReturn(List.of(borrow));
        assertEquals(List.of(),prefix(List.of(group),List.of(parent,child),List.of()));
    }
}
