package com.uten.imp.features.subcontract.waste;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SubcontractNormalMaterialLossBudgetTest {
    @Test void thousandFinishedTargetAnd1100MaterialBudgetKeep100NormalMaterialLoss() {
        amount("100",remaining("1000","1.1","1","0","0"));
        // Actual 900 finished leaves 200 material; its split is 100 normal and 100 excess.
        amount("100",new BigDecimal("200").subtract(remaining("1000","1.1","1","0","0")));
    }
    @Test void aLegacyPlanWithoutAdditionalMaterialDoesNotAcquireAModernNormalLossBudget() {
        amount("0",remaining("1000","1","1","0","0"));
    }
    @Test void approvedNormalLossIsSpentOnceAndReversalIsReadFromCurrentAuthoritativeFacts() {
        amount("70",remaining("1000","1.1","1","30","0"));
        amount("100",remaining("1000","1.1","1","0","0"));
        amount("0",remaining("1000","1.1","1","120","0"));
    }
    @Test void materialBudgetsKeepTheirOwnBaseUnitsAndTheirFinalQuantityTick() {
        amount("200",remaining("1000","2.2","2","0","0"));
        amount("0.000001",remaining("10000","0.0000010001","0.000001","0","0"));
        assertThrows(RuntimeException.class,()->remaining(null,"1.1","1","0","0"));
    }
    @Test void differentIssueUnitsSpendOneSharedMaterialBudgetInBaseUnits() {
        var first=SubcontractWasteService.allocateNormalMaterialBudget(new BigDecimal("100"),new BigDecimal("20"),new BigDecimal("2"));
        amount("20",first.standardDoc());amount("40",first.originalBase());amount("60",first.remainingBase());
        var second=SubcontractWasteService.allocateNormalMaterialBudget(first.remainingBase(),new BigDecimal("50"),new BigDecimal("3"));
        amount("20",second.standardDoc());amount("60",second.originalBase());amount("0",second.remainingBase());
    }
    @Test void aRepeatingUnitConversionRequiresAnActualPrecisionChoice() {
        assertThrows(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class,()->
                SubcontractWasteService.allocateNormalMaterialBudget(new BigDecimal("100"),new BigDecimal("100"),new BigDecimal("3")));
    }
    @Test void legacyImplicitNormalLossSpendsTheBudgetBeforeAnotherActualWaste() {
        var implicit=SubcontractWasteService.historicalNormalMaterialUsed(new BigDecimal("1045"),new BigDecimal("950"),new BigDecimal("95"));
        amount("95",implicit);
        var available=remaining("1000","1.1","1","0",implicit.toPlainString());
        amount("5",available);
        var allocation=SubcontractWasteService.allocateNormalMaterialBudget(available,new BigDecimal("55"),BigDecimal.ONE);
        amount("5",allocation.standardDoc());amount("50",new BigDecimal("55").subtract(allocation.standardDoc()));
    }
    @Test void oldRoundingRemaindersDoNotCreateANewNormalLossAllowance() {
        var implicit=SubcontractWasteService.historicalNormalMaterialUsed(new BigDecimal("0.0101"),new BigDecimal("0.01"),new BigDecimal("0.000001"));
        amount("0.000001",implicit);
        amount("0",remaining("10000","0.0000010001","0.000001","0",implicit.toPlainString()));
    }
    private static BigDecimal remaining(String output,String budgetUnit,String baseUnit,String explicit,String implicit) {
        BigDecimal allowance=SubcontractWasteService.normalMaterialAllowance(output==null?null:new BigDecimal(output),new BigDecimal(budgetUnit),new BigDecimal(baseUnit));
        return SubcontractWasteService.remainingNormalMaterialBudget(allowance,new BigDecimal(explicit),new BigDecimal(implicit));
    }
    private static void amount(String expected,BigDecimal actual) { assertEquals(0,new BigDecimal(expected).compareTo(actual)); }
}
