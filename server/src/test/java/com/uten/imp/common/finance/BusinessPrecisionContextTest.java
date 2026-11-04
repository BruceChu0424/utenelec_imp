package com.uten.imp.common.finance;

import org.junit.jupiter.api.Test;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class BusinessPrecisionContextTest {
 @Test void sqlRejectedChoiceSurvivesTranslationButCannotEraseAnEarlierCommittedWrite()throws Exception{
  var postgres=org.mockito.Mockito.mock(org.postgresql.util.PSQLException.class);
  var message=org.mockito.Mockito.mock(org.postgresql.util.ServerErrorMessage.class);
  org.mockito.Mockito.when(postgres.getSQLState()).thenReturn("22023");org.mockito.Mockito.when(postgres.getServerErrorMessage()).thenReturn(message);
  org.mockito.Mockito.when(message.getMessage()).thenReturn("UTEN_PRECISION_REQUIRED:{\"calculationKey\":\"quantity.share\",\"label\":\"来源容量需要更多位数\",\"maxScale\":24,\"reason\":\"PRECISION_LIMIT\",\"notWritten\":true,\"selectionRejected\":true}");
  try(var operation=BusinessPrecisionContext.use(Map.of())){
   assertThat(BusinessPrecisionRequiredException.from(postgres).orElseThrow().details()).containsEntry("selectionRejected",true).containsEntry("notWritten",true);
   BusinessPrecisionContext.writeCommitted();
   assertThat(BusinessPrecisionRequiredException.from(postgres).orElseThrow().details()).containsEntry("selectionRejected",true).containsEntry("notWritten",false);
  }
 }
 @Test void sqlChoiceReplacementMarkerMustBeABoolean(){
  var postgres=org.mockito.Mockito.mock(org.postgresql.util.PSQLException.class);var message=org.mockito.Mockito.mock(org.postgresql.util.ServerErrorMessage.class);
  org.mockito.Mockito.when(postgres.getSQLState()).thenReturn("22023");org.mockito.Mockito.when(postgres.getServerErrorMessage()).thenReturn(message);
  org.mockito.Mockito.when(message.getMessage()).thenReturn("UTEN_PRECISION_REQUIRED:{\"calculationKey\":\"ratio\",\"label\":\"本次比例\",\"maxScale\":24,\"reason\":\"PRECISION_LIMIT\",\"notWritten\":true,\"selectionRejected\":\"true\"}");
  assertThat(BusinessPrecisionRequiredException.from(postgres).orElseThrow().details()).doesNotContainKey("selectionRejected");
 }
 @Test void finiteValuesAreCompleteEvenWhenAChoiceExistsForOtherRepeatingValues()throws Exception{
  try(var ignored=BusinessPrecisionContext.use(Map.of("ratio",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
   assertThat(BusinessPrecisionContext.divide(BigDecimal.ONE,new BigDecimal("8"),"ratio","本次比例",30)).isEqualByComparingTo("0.125");
   assertThat(BusinessPrecisionContext.divide(BigDecimal.ONE,new BigDecimal("1048576"),"ratio","本次比例",30)).isEqualByComparingTo("0.00000095367431640625");
   assertThat(BusinessPrecisionContext.usedChoices()).isEmpty();
  }
 }
 @Test void repeatingResultHasNoImplicitRoundingAndExplicitModesMatchBothSigns()throws Exception{
  assertThatThrownBy(()->BusinessPrecisionContext.divide(BigDecimal.ONE,new BigDecimal("3"),"ratio","本次比例",30)).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("notWritten",true).containsEntry("reason","NON_TERMINATING"));
  try(var ignored=BusinessPrecisionContext.use(Map.of("ratio",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
   assertThat(BusinessPrecisionContext.divide(new BigDecimal("2"),new BigDecimal("3"),"ratio","本次比例",30)).isEqualByComparingTo("0.67");
   assertThat(BusinessPrecisionContext.divide(new BigDecimal("-2"),new BigDecimal("3"),"ratio","本次比例",30)).isEqualByComparingTo("-0.67");
  }
  try(var ignored=BusinessPrecisionContext.use(Map.of("ratio",new BusinessPrecisionContext.Choice(2,"DOWN")))){
   assertThat(BusinessPrecisionContext.divide(new BigDecimal("-2"),new BigDecimal("3"),"ratio","本次比例",30)).isEqualByComparingTo("-0.66");
  }
  assertThat(BusinessPrecisionContext.choices()).isEmpty();
 }
 @Test void excessiveFinitePrecisionAsksAndNeverSilentlyQuantizesInput(){
  assertThatThrownBy(()->BusinessPrecisionContext.limit(new BigDecimal("1.234567"),"limited","本次字段",4)).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("reason","PRECISION_LIMIT"));
  assertThat(MoneyPolicy.quantity(new BigDecimal("123.123456789012345678901234"))).isEqualByComparingTo("123.123456789012345678901234");
 }
 @Test void explicitChoicesAreRequestScopedAndOnlyKnownModesAreAccepted()throws Exception{
  String raw="{\"version\":1,\"choices\":{\"money.cumulative-share\":{\"scale\":4,\"rounding\":\"DOWN\"}}}";
  var parsed=BusinessPrecisionContext.parse(Base64.getUrlEncoder().withoutPadding().encodeToString(raw.getBytes(StandardCharsets.UTF_8)));
  try(var ignored=BusinessPrecisionContext.use(parsed)){assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("100"),BigDecimal.ONE,new BigDecimal("3"))).isEqualByComparingTo("33.3333");}
 }
 @Test void aPriorCommittedWriteCannotBeAdvertisedAsAnUnwrittenOperation()throws Exception{
  try(var ignored=BusinessPrecisionContext.use(Map.of())){
   BusinessPrecisionContext.writeCommitted();
   assertThatThrownBy(()->BusinessPrecisionContext.divide(BigDecimal.ONE,new BigDecimal("3"),"ratio","本次比例",30))
       .isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("notWritten",false));
  }
  assertThat(BusinessPrecisionContext.canProveUnwritten()).isTrue();
 }
 @Test void nestedChoicesCannotEraseEarlierBusinessCommitsAndMetadataDoesNotInventOne()throws Exception{
  try(var operation=BusinessPrecisionContext.use(Map.of())){
   try(var metadata=BusinessPrecisionContext.useMetadata()){BusinessPrecisionContext.writeCommitted();}
   assertThat(BusinessPrecisionContext.canProveUnwritten()).isTrue();
   BusinessPrecisionContext.writeCommitted();
   try(var nested=BusinessPrecisionContext.use(Map.of())){
    assertThat(BusinessPrecisionContext.canProveUnwritten()).isFalse();
    assertThatThrownBy(()->BusinessPrecisionContext.divide(BigDecimal.ONE,new BigDecimal("3"),"ratio","本次比例",30))
        .isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("notWritten",false));
   }
  }
 }
}
