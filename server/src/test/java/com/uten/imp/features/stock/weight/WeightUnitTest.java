package com.uten.imp.features.stock.weight;

import com.uten.imp.common.measure.WeightUnit;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** 单位换算保留有限原值；除不尽使用本次用户选择，不再默认为4/6位。 */
class WeightUnitTest {

    @Test
    void factorsMatchTheClosedCatalogue() {
        assertThat(WeightUnit.G.kgPerUnit()).isEqualByComparingTo("0.001");
        assertThat(WeightUnit.KG.kgPerUnit()).isEqualByComparingTo("1");
        assertThat(WeightUnit.T.kgPerUnit()).isEqualByComparingTo("1000");
        assertThat(WeightUnit.JIN.kgPerUnit()).isEqualByComparingTo("0.5");
        assertThat(WeightUnit.LB.kgPerUnit()).isEqualByComparingTo("0.45359237");
        assertThat(WeightUnit.OZ.kgPerUnit()).isEqualByComparingTo("0.028349523125");
        assertThat(WeightUnit.values()).extracting(WeightUnit::code)
                .containsExactly("G", "KG", "T", "JIN", "LB", "OZ");
        assertThat(WeightUnit.JIN.label()).isEqualTo("斤");
        assertThat(WeightUnit.OZ.symbol()).isEqualTo("oz");
    }

    @Test
    void lineConversionKeepsSmallWeightsAndAllFinitePoundOunceDigits() {
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("850"))).isEqualByComparingTo("0.85");
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("0.05"))).isEqualByComparingTo("0.00005");
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("0.04"))).isEqualByComparingTo("0.00004");
        assertThat(WeightUnit.T.toKgLine(new BigDecimal("1.2"))).isEqualByComparingTo("1200");
        assertThat(WeightUnit.JIN.toKgLine(new BigDecimal("3"))).isEqualByComparingTo("1.5");
        assertThat(WeightUnit.LB.toKgLine(new BigDecimal("2"))).isEqualByComparingTo("0.90718474");
        assertThat(WeightUnit.OZ.toKgLine(new BigDecimal("1"))).isEqualByComparingTo("0.028349523125");
        assertThat(WeightUnit.KG.toKgLine(null)).isNull();
    }

    @Test
    void finiteConversionRoundTripsAndRepeatingConversionRequiresAnExplicitChoice() throws Exception {
        assertThat(WeightUnit.G.toKgPrecise(new BigDecimal("46.2"))).isEqualByComparingTo("0.0462");
        assertThat(WeightUnit.LB.toKgPrecise(new BigDecimal("1"))).isEqualByComparingTo("0.45359237");
        assertThat(WeightUnit.G.fromKg(new BigDecimal("0.8500"), 1)).isEqualByComparingTo("850");
        assertThat(WeightUnit.T.fromKg(new BigDecimal("3520"), 3)).isEqualByComparingTo("3.52");
        assertThat(WeightUnit.JIN.fromKg(new BigDecimal("1.25"), 2)).isEqualByComparingTo("2.5");
        assertThatThrownBy(()->WeightUnit.LB.fromKg(BigDecimal.ONE,4)).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
        try(var choice=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of("weight.from-kg",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"HALF_UP")))){
            assertThat(WeightUnit.LB.fromKg(BigDecimal.ONE,4)).isEqualByComparingTo("2.2046");
        }
        assertThat(WeightUnit.KG.fromKg(null, 3)).isNull();
    }

    @Test
    void parseAcceptsCodesSymbolsAndLabelsCaseInsensitively() {
        assertThat(WeightUnit.parse("kg")).isEqualTo(WeightUnit.KG);
        assertThat(WeightUnit.parse(" KG ")).isEqualTo(WeightUnit.KG);
        assertThat(WeightUnit.parse("千克")).isEqualTo(WeightUnit.KG);
        assertThat(WeightUnit.parse("公斤")).isEqualTo(WeightUnit.KG);
        assertThat(WeightUnit.parse("g")).isEqualTo(WeightUnit.G);
        assertThat(WeightUnit.parse("克")).isEqualTo(WeightUnit.G);
        assertThat(WeightUnit.parse("t")).isEqualTo(WeightUnit.T);
        assertThat(WeightUnit.parse("吨")).isEqualTo(WeightUnit.T);
        assertThat(WeightUnit.parse("jin")).isEqualTo(WeightUnit.JIN);
        assertThat(WeightUnit.parse("斤")).isEqualTo(WeightUnit.JIN);
        assertThat(WeightUnit.parse("Lb")).isEqualTo(WeightUnit.LB);
        assertThat(WeightUnit.parse("lbs")).isEqualTo(WeightUnit.LB);
        assertThat(WeightUnit.parse("磅")).isEqualTo(WeightUnit.LB);
        assertThat(WeightUnit.parse("OZ")).isEqualTo(WeightUnit.OZ);
        assertThat(WeightUnit.parse("盎司")).isEqualTo(WeightUnit.OZ);
        assertThat(WeightUnit.tryParse("个")).isEmpty();
        assertThat(WeightUnit.tryParse(null)).isEmpty();
        assertThatThrownBy(() -> WeightUnit.parse("箱")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> WeightUnit.parse(" ")).isInstanceOf(IllegalArgumentException.class);
    }
}
