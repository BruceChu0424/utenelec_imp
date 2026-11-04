package com.uten.imp.features.stock.weight;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.features.stock.StockService;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
class WeightExactMathTest {
 @Test void finiteInputAndProductKeepEveryDigitEvenWithLowerExplicitScale() throws Exception {
  try(var ignored=BusinessPrecisionContext.use(Map.of("weight.to-kg",new BusinessPrecisionContext.Choice(2,"DOWN"),"weight.kg-field",new BusinessPrecisionContext.Choice(2,"DOWN")))){
   assertThat(WeightUnit.G.toKgLine(new BigDecimal("0.04"))).isEqualByComparingTo("0.00004");
   assertThat(WeightMath.times(new BigDecimal("1.123456789012345678901234"),BigDecimal.ONE)).isEqualByComparingTo("1.123456789012345678901234");
   assertThat(WeightMath.prorate(new BigDecimal("0.000000000000000000000001"),BigDecimal.ONE,BigDecimal.ONE)).isEqualByComparingTo("0.000000000000000000000001");
  }
 }
 @Test void repeatingAndBeyondFieldPrecisionRequireCurrentChoice() throws Exception {
  assertThatThrownBy(()->WeightMath.prorate(BigDecimal.ONE,BigDecimal.ONE,new BigDecimal("3"))).isInstanceOf(BusinessPrecisionRequiredException.class);
  assertThatThrownBy(()->WeightUnit.LB.toKgLine(new BigDecimal("0.000000000000000000000001"))).isInstanceOf(BusinessPrecisionRequiredException.class);
  try(var ignored=BusinessPrecisionContext.use(Map.of("weight.prorate",new BusinessPrecisionContext.Choice(5,"DOWN")))){
   assertThat(WeightMath.prorate(BigDecimal.ONE,BigDecimal.ONE,new BigDecimal("3"))).isEqualByComparingTo("0.33333");
  }
 }
 @Test void massGoodsLegacyReversalUsesOriginalKilogramsInsteadOfNewProduct(){
  var ctx=new StockWeightResolver.WeightContext(new BigDecimal("3.25"),new BigDecimal("0.0033"),false,true,new BigDecimal("0.001"),null,
   new StockWeightResolver.Pool(new BigDecimal("3.25"),BigDecimal.ZERO,new BigDecimal("0.0033"),BigDecimal.ZERO,true,WeightSource.EXACT),null,null);
  var req=new StockService.MovementRequest(OffsetDateTime.now(),(short)11,"STOCK_DOC",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),null,UUID.randomUUID(),StockService.DIR_OUT,new BigDecimal("3.25"),null,BigDecimal.ONE,null,"fixture",null);
  var value=StockWeightResolver.resolve(ctx,req);
  assertThat(value.weightKg()).isEqualByComparingTo("0.0033");assertThat(value.balanceWeightAfter()).isEqualByComparingTo(BigDecimal.ZERO);
 }
 @Test void oldMassPrefixAndNewExactInboundRemainContinuousAndFinalOutTakesActualRemainder(){
  var req=new StockService.MovementRequest(OffsetDateTime.now(),(short)11,"STOCK_DOC",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),null,UUID.randomUUID(),StockService.DIR_IN,BigDecimal.ONE,null,BigDecimal.ONE,null,"fixture",null);
  var old=new StockWeightResolver.WeightContext(new BigDecimal("10"),new BigDecimal("4.5359"),false,true,new BigDecimal("0.45359237"),null,null,null,null);
  var added=StockWeightResolver.resolve(old,req);assertThat(added.weightKg()).isEqualByComparingTo("0.45359237");assertThat(added.balanceWeightAfter()).isEqualByComparingTo("4.98949237");
  var after=new StockWeightResolver.WeightContext(new BigDecimal("11"),added.balanceWeightAfter(),false,true,new BigDecimal("0.45359237"),null,null,null,null);
  var out=new StockService.MovementRequest(OffsetDateTime.now(),(short)3,"STOCK_DOC",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),null,UUID.randomUUID(),StockService.DIR_OUT,new BigDecimal("11"),null,BigDecimal.ONE,null,"fixture",null);
  var full=StockWeightResolver.resolve(after,out);assertThat(full.weightKg()).isEqualByComparingTo("4.98949237");assertThat(full.source()).isEqualTo(WeightSource.SLICE);assertThat(full.balanceWeightAfter()).isEqualByComparingTo(BigDecimal.ZERO);
 }
 @Test void selectedCoarseRoundingOverSourceRequiresReselection() throws Exception {
  try(var ignored=BusinessPrecisionContext.use(Map.of("weight.prorate",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){
   var failure=org.junit.jupiter.api.Assertions.assertThrows(BusinessPrecisionRequiredException.class,()->WeightMath.prorate(new BigDecimal("0.9"),new BigDecimal("0.9"),new BigDecimal("1.1")));
   assertThat(failure).isNotNull();assertThat(failure.details()).containsEntry("selectionRejected",true).containsEntry("notWritten",true);
  }
 }
}
