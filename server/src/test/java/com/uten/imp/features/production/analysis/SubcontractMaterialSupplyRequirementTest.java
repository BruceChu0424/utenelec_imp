package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SubcontractMaterialSupplyRequirementTest {
    @Test void uncommittedOutputRequiresOnlyItsBomMaterials() {
        var rule=SubcontractMaterialSupplyRequirement.NONE;
        quantity("1000",required(rule,"1000"));
        quantity("0",required(rule,"0"));
        quantity("500",required(rule,"500"));
    }

    @Test void frozenTailKeepsExactMaterialBudgetInsteadOfMultiplyingRoundedFinishedShortage() {
        var rule=rule("98.5049","101.46");
        quantity("101.46",required(rule,"98.5049"));
        quantity("111.46",required(rule,"108.5049"));
        quantity("0",required(rule,"0"));
    }

    @Test void finishedTargetRemovesUnusedBudgetRatherThanCreatingAnotherProductionObligation() {
        var rule=rule("0","100");
        quantity("0",required(rule,"0"));
        quantity("10",required(rule,"10"));
    }

    @Test void minimumUsageIsMultipliedBeforeTheOnlyMaterialCeiling() {
        var rule=SubcontractMaterialSupplyRequirement.NONE;
        quantity("0.0101",rule.required(new BigDecimal("10001"),new BigDecimal("0.000001"),
                "PER_UNIT",BigDecimal.ONE,true));
    }

    @Test void completedBatchCanReceivePrivateReplacementQuotaWithoutReusingItsOldIssuedAmount() {
        quantity("101.46",MaterialAnalysisCommandService.additionalPrivateMakeQuota(new BigDecimal("101.46"),BigDecimal.ZERO));
        quantity("61.46",MaterialAnalysisCommandService.additionalPrivateMakeQuota(new BigDecimal("101.46"),new BigDecimal("40")));
        quantity("0",MaterialAnalysisCommandService.additionalPrivateMakeQuota(new BigDecimal("101.46"),new BigDecimal("101.46")));
        quantity("0",MaterialAnalysisCommandService.additionalPrivateMakeQuota(BigDecimal.ZERO,new BigDecimal("3382")));
    }

    @Test void invalidFrozenQuantityCannotBecomeABaselineFallback() {
        assertThrows(IllegalArgumentException.class,()->rule("0","-1"));
        assertThrows(IllegalArgumentException.class,()->rule("-1","0"));
    }

    @Test void anApproved1100PrivateMaterialBudgetIsProtectedBeforeASiblingCanAllocateThePool() {
        UUID source=UUID.randomUUID(),siblingSource=UUID.randomUUID(),unit=UUID.randomUUID(),goods=UUID.randomUUID();
        var parent=node(source,UUID.randomUUID(),unit,"parent",null,1,"1000","1","SUBCONTRACT",true);
        var child=node(source,goods,unit,"parent/child","parent",2,"1000","1","MAKE",true)
                .withSupplyRequirement(rule("1000","1100"));
        var raw=node(source,UUID.randomUUID(),unit,"parent/child/raw","parent/child",3,"2000","2","BUY",false);
        var sibling=node(siblingSource,goods,unit,"sibling",null,1,"100","1","BUY",false);
        var gross=MaterialAnalysisService.withGrossSupplyBudget(List.of(parent,child,raw,sibling));
        quantity("1100",gross.get(1).snapshotRequiredQty());quantity("2200",gross.get(2).snapshotRequiredQty());
        quantity("1",gross.get(1).bomQty());
        var protection=MaterialAnalysisService.planExactPegs(List.of(new MaterialAnalysisService.ExactPegRecord(
                UUID.randomUUID(),UUID.randomUUID(),source,child.nodeKey(),child.dimension(),new BigDecimal("1100"))),
                gross,Map.of(child.dimension(),new BigDecimal("1100")));
        quantity("1100",protection.securedHeadroomDiagnostic(source+"|"+child.nodeKey()));
        quantity("0",protection.securedHeadroomDiagnostic(siblingSource+"|"+sibling.nodeKey()));
        var allocated=MaterialAnalysisService.allocateNestedDiagnostics(List.of(),gross,
                Map.of(child.dimension(),BigDecimal.ZERO),Map.of(),Set.of(),protection);
        quantity("1100",allocated.nodeAllocations().get(source+"|"+child.nodeKey()).allocatedQty());
        quantity("0",allocated.nodeAllocations().get(siblingSource+"|"+sibling.nodeKey()).allocatedQty());
    }

    private static MaterialAnalysisService.BomNode node(UUID source,UUID goods,UUID unit,String path,String parent,
            int depth,String required,String usage,String route,boolean children) {
        return new MaterialAnalysisService.BomNode(source,UUID.randomUUID(),UUID.randomUUID(),goods,null,unit,
                depth,path,parent,BigDecimal.ONE,new BigDecimal(usage),BigDecimal.ONE,new BigDecimal(required),
                path,path,null,null,"个",BigDecimal.ZERO,route,children,"START","PER_UNIT",BigDecimal.ONE,true,true);
    }

    private static SubcontractMaterialSupplyRequirement rule(String output,String material) {
        return new SubcontractMaterialSupplyRequirement(new BigDecimal(output),new BigDecimal(material));
    }
    private static BigDecimal required(SubcontractMaterialSupplyRequirement rule,String output) {
        return rule.required(new BigDecimal(output),BigDecimal.ONE,"PER_UNIT",BigDecimal.ONE,true);
    }
    private static void quantity(String expected,BigDecimal actual) {
        assertEquals(0,new BigDecimal(expected).compareTo(actual),()->"expected "+expected+" but got "+actual);
    }
}
