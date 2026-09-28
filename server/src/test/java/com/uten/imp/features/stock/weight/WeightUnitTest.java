package com.uten.imp.features.stock.weight;

import com.uten.imp.common.measure.WeightUnit;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** 重量单位换算与解析 (ADR-135 §1): 库内一律 kg, 单据行 4 位、学习数据 6 位, 四舍五入。 */
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
    void lineConversionRoundsHalfUpToFourDecimals() {
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("850"))).isEqualByComparingTo("0.8500")
                .hasScaleOf(4);
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("0.05"))).isEqualTo(new BigDecimal("0.0001"));
        assertThat(WeightUnit.G.toKgLine(new BigDecimal("0.04"))).isEqualTo(new BigDecimal("0.0000"));
        assertThat(WeightUnit.T.toKgLine(new BigDecimal("1.2"))).isEqualTo(new BigDecimal("1200.0000"));
        assertThat(WeightUnit.JIN.toKgLine(new BigDecimal("3"))).isEqualTo(new BigDecimal("1.5000"));
        assertThat(WeightUnit.LB.toKgLine(new BigDecimal("2"))).isEqualTo(new BigDecimal("0.9072"));
        assertThat(WeightUnit.OZ.toKgLine(new BigDecimal("1"))).isEqualTo(new BigDecimal("0.0283"));
        assertThat(WeightUnit.KG.toKgLine(null)).isNull();
    }

    @Test
    void preciseConversionKeepsSixDecimalsAndFromKgRoundTrips() {
        assertThat(WeightUnit.G.toKgPrecise(new BigDecimal("46.2"))).isEqualTo(new BigDecimal("0.046200"));
        assertThat(WeightUnit.LB.toKgPrecise(new BigDecimal("1"))).isEqualTo(new BigDecimal("0.453592"));
        assertThat(WeightUnit.G.fromKg(new BigDecimal("0.8500"), 1)).isEqualTo(new BigDecimal("850.0"));
        assertThat(WeightUnit.T.fromKg(new BigDecimal("3520"), 3)).isEqualTo(new BigDecimal("3.520"));
        assertThat(WeightUnit.JIN.fromKg(new BigDecimal("1.25"), 2)).isEqualTo(new BigDecimal("2.50"));
        assertThat(WeightUnit.LB.fromKg(new BigDecimal("1"), 4)).isEqualTo(new BigDecimal("2.2046"));
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
