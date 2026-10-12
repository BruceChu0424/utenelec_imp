package com.uten.imp.features.purchase.order;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
class PurchaseOrderGiftAllocationTest {
 private static BigDecimal n(String value){return new BigDecimal(value);}
 private static PurchaseOrderService.PhysicalShare physical(String value){return new PurchaseOrderService.PhysicalShare(UUID.randomUUID(),n(value));}
 @Test void twoTenUnitPhysicalNeedsReceiveNineChargedAndOneFreeEach(){
  var splits=PurchaseOrderService.allocateSourceShares(List.of(physical("10"),physical("10")),n("18"),n("2"));
  assertThat(splits).hasSize(2);for(var split:splits){assertThat(split.allocQty()).isEqualByComparingTo("9");assertThat(split.allocGiftQty()).isEqualByComparingTo("1");}
 }
 @Test void tinyRemaindersStayWithinEachActualPhysicalSourceAndNoQuantityIsLost(){
  var sources=List.of(physical("0.0001"),physical("0.0001"),physical("0.0001"));
  for(String paid:List.of("0.0001","0.0002")){
   BigDecimal free=n("0.0003").subtract(n(paid));var splits=PurchaseOrderService.allocateSourceShares(sources,n(paid),free);
   assertThat(splits.stream().map(PurchaseOrderService.SourceSplit::allocQty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo(paid);
   assertThat(splits.stream().map(PurchaseOrderService.SourceSplit::allocGiftQty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo(free);
   for(var split:splits){assertThat(split.allocQty()).isNotNegative();assertThat(split.allocGiftQty()).isNotNegative();assertThat(split.allocQty().add(split.allocGiftQty())).isEqualByComparingTo("0.0001");}
  }
 }
 @Test void freeOnlyMergedSourcesOwnTheirOwnFreeSharesAndCreateNoPaidAllocation(){
  var splits=PurchaseOrderService.allocateSourceShares(List.of(physical("1"),physical("2")),n("0"),n("3"));
  assertThat(splits.get(0).allocQty()).isZero();assertThat(splits.get(1).allocQty()).isZero();assertThat(splits.get(0).allocGiftQty()).isEqualByComparingTo("1");assertThat(splits.get(1).allocGiftQty()).isEqualByComparingTo("2");
 }
 @Test void manualDocumentsDoNotInventUpstreamShares(){assertThat(PurchaseOrderService.allocateSourceShares(List.of(),n("10"),n("1"))).isEmpty();}
 @Test void legacyGiftAnnotationsKeepTheirRecordedPhysicalQuantityAndRejectEmptyLegacyMovement(){
  assertThat(com.uten.imp.common.finance.ProcurementQuantities.physicalText(com.uten.imp.common.finance.ProcurementQuantities.LEGACY,n("10"),n("1"))).isEqualTo("10");
  assertThat(com.uten.imp.common.finance.ProcurementQuantities.physicalText(com.uten.imp.common.finance.ProcurementQuantities.EXTRA_GIFT,n("10"),n("1"))).isEqualTo("11");
  org.assertj.core.api.Assertions.assertThatThrownBy(()->com.uten.imp.common.finance.ProcurementQuantities.of(com.uten.imp.common.finance.ProcurementQuantities.LEGACY,n("0"),n("1"),n("1"))).isInstanceOf(com.uten.imp.common.web.ApiException.class);
  org.assertj.core.api.Assertions.assertThatThrownBy(()->com.uten.imp.common.finance.ProcurementQuantities.of(com.uten.imp.common.finance.ProcurementQuantities.EXTRA_GIFT,n("10"),n("-1"),n("1"))).isInstanceOf(com.uten.imp.common.web.ApiException.class);
 }
}
