package com.uten.imp.common.finance;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
class ChineseMoneyUppercaseTest {
 @Test void preservesExactCentsZerosSignsAndLongDecimalAmounts(){
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("100000001.05"))).isEqualTo("人民币壹亿零壹元零伍分");
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("-1.12"))).isEqualTo("人民币负壹元壹角贰分");
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("0.05"))).isEqualTo("人民币伍分");
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("0.50"))).isEqualTo("人民币伍角");
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("0.00"))).isEqualTo("人民币零元整");
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("90071992547409.12"))).isEqualTo("人民币玖拾万亿零柒佰壹拾玖亿玖仟贰佰伍拾肆万柒仟肆佰零玖元壹角贰分");
 }
 @Test void neverRoundsSubCentOrUnsupportedMagnitudeToACompleteMoneyText(){
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("1.005"))).isNull();
  assertThat(ChineseMoneyUppercase.format(new BigDecimal("10000000000000000000000000000"))).isNull();
 }
}
