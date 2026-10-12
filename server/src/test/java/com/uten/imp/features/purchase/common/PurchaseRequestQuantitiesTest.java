package com.uten.imp.features.purchase.common;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import com.uten.imp.common.finance.ProcurementQuantities;
import static org.assertj.core.api.Assertions.assertThat;
class PurchaseRequestQuantitiesTest {
 private static BigDecimal n(String value){return new BigDecimal(value);}
 @Test void unpromisedFreeSupplyCanFulfilTenPhysicalUnitsWithoutRewritingTheTenPaidNeed(){
  var actual=PurchaseRequestQuantities.remaining(ProcurementQuantities.EXTRA_GIFT,n("10"),n("0"),n("9"),n("1"),n("0"),n("0"));
  assertThat(actual.physicalRequired()).isEqualByComparingTo("10");assertThat(actual.physicalOrdered()).isEqualByComparingTo("10");assertThat(actual.chargedRemaining()).isZero();assertThat(actual.giftRemaining()).isZero();
 }
 @Test void anOutstandingPromisedGiftDoesNotBecomeAnAdditionalPaidNeed(){
  var actual=PurchaseRequestQuantities.remaining(ProcurementQuantities.EXTRA_GIFT,n("10"),n("1"),n("10"),n("0"),n("0"),n("0"));
  assertThat(actual.physicalRequired()).isEqualByComparingTo("11");assertThat(actual.physicalRemaining()).isEqualByComparingTo("1");assertThat(actual.chargedRemaining()).isZero();assertThat(actual.giftRemaining()).isEqualByComparingTo("1");
 }
 @Test void aPendingAllFreeCommitmentOccupiesThePhysicalNeedWithoutChargingIt(){
  var actual=PurchaseRequestQuantities.remaining(ProcurementQuantities.EXTRA_GIFT,n("0"),n("1"),n("0"),n("0"),n("0"),n("1"));
  assertThat(actual.physicalRequired()).isEqualByComparingTo("1");assertThat(actual.physicalPending()).isEqualByComparingTo("1");assertThat(actual.physicalRemaining()).isZero();
 }
 @Test void legacyGiftAnnotationsNeverIncreaseDemandAndNewFreeSupplyStillHasActualPhysicalQuantity(){
  var actual=PurchaseRequestQuantities.remaining(ProcurementQuantities.LEGACY,n("10"),n("99"),n("9"),n("1"),n("0"),n("0"));
  assertThat(actual.physicalRequired()).isEqualByComparingTo("10");assertThat(actual.physicalRemaining()).isZero();
 }
 @Test void quantitiesKeepEveryLegalDigitAndRemainingNeverTurnsAnOverPurchaseIntoNegativeSupply(){
  var actual=PurchaseRequestQuantities.remaining(ProcurementQuantities.EXTRA_GIFT,n("99999999999999.1234"),n("0"),n("99999999999998.0000"),n("0.1234"),n("0"),n("0"));
  assertThat(actual.physicalRemaining()).isEqualByComparingTo("1.0000");
  var over=PurchaseRequestQuantities.remaining(ProcurementQuantities.EXTRA_GIFT,n("10"),n("1"),n("12"),n("0"),n("0"),n("0"));
  assertThat(over.physicalRemaining()).isZero();assertThat(over.giftRemaining()).isZero();
 }
}
