package com.uten.imp.common.measure;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Locale;
import java.util.Optional;

/**
 * 重量单位 (ADR-135): 封闭目录, 库内一律按千克 (kg) 存。
 *
 * <p>单据/称重行的重量列都是 NUMERIC(18,4) kg (0.1 g), 客户端先换算成 kg 再四舍五入到 4 位,
 * 服务端用 {@link #toKgLine} 同式复核; 称样等学习数据用 {@link #toKgPrecise} (6 位)。
 * 重量是数量口径, 不属于金额舍入范围 (common/measure 不在金额锁边扫描内)。
 */
public enum WeightUnit {
    G("G", "克", "g", new BigDecimal("0.001")),
    KG("KG", "千克", "kg", BigDecimal.ONE),
    T("T", "吨", "t", new BigDecimal("1000")),
    JIN("JIN", "斤", "斤", new BigDecimal("0.5")),
    LB("LB", "磅", "lb", new BigDecimal("0.45359237")),
    OZ("OZ", "盎司", "oz", new BigDecimal("0.028349523125"));

    /** 单据行重量 (kg) 的小数位: 0.1 g。 */
    public static final int LINE_SCALE = 4;
    /** 学习数据 (观测) 重量 (kg) 的小数位。 */
    public static final int PRECISE_SCALE = 6;

    private final String code;
    private final String label;
    private final String symbol;
    private final BigDecimal kgPerUnit;

    WeightUnit(String code, String label, String symbol, BigDecimal kgPerUnit) {
        this.code = code;
        this.label = label;
        this.symbol = symbol;
        this.kgPerUnit = kgPerUnit;
    }

    /** 存库/接口用的代码 (G/KG/T/JIN/LB/OZ)。 */
    public String code() {
        return code;
    }

    /** 中文名称 (克/千克/吨/斤/磅/盎司)。 */
    public String label() {
        return label;
    }

    /** 显示符号 (g/kg/t/斤/lb/oz)。 */
    public String symbol() {
        return symbol;
    }

    /** 1 个本单位等于多少千克 (精确值)。 */
    public BigDecimal kgPerUnit() {
        return kgPerUnit;
    }

    /** 单据行口径: value 换算成 kg, 四舍五入到 4 位; null 原样返回。 */
    public BigDecimal toKgLine(BigDecimal value) {
        return value == null ? null : value.multiply(kgPerUnit).setScale(LINE_SCALE, RoundingMode.HALF_UP);
    }

    /** 学习数据口径: value 换算成 kg, 四舍五入到 6 位; null 原样返回。 */
    public BigDecimal toKgPrecise(BigDecimal value) {
        return value == null ? null : value.multiply(kgPerUnit).setScale(PRECISE_SCALE, RoundingMode.HALF_UP);
    }

    /** kg 换算回本单位, 四舍五入到指定小数位; null 原样返回。 */
    public BigDecimal fromKg(BigDecimal kg, int scale) {
        if (kg == null) {
            return null;
        }
        if (scale < 0) {
            throw new IllegalArgumentException("scale must be >= 0");
        }
        return kg.divide(kgPerUnit, scale, RoundingMode.HALF_UP);
    }

    /**
     * 按代码、符号或中文名称解析 (不区分大小写, 去首尾空白), 另认「公斤」「lbs」两个常见写法。
     *
     * @throws IllegalArgumentException 空值或不认识的单位
     */
    public static WeightUnit parse(String text) {
        return tryParse(text).orElseThrow(() -> new IllegalArgumentException(
                "不认识的重量单位: " + (text == null ? "(空)" : text.strip())));
    }

    /** 同 {@link #parse}, 不认识时返回空。 */
    public static Optional<WeightUnit> tryParse(String text) {
        if (text == null) {
            return Optional.empty();
        }
        String value = text.strip();
        if (value.isEmpty()) {
            return Optional.empty();
        }
        String lower = value.toLowerCase(Locale.ROOT);
        for (WeightUnit unit : values()) {
            if (unit.code.equalsIgnoreCase(value)
                    || unit.symbol.toLowerCase(Locale.ROOT).equals(lower)
                    || unit.label.equals(value)) {
                return Optional.of(unit);
            }
        }
        return switch (lower) {
            case "公斤" -> Optional.of(KG);
            case "lbs" -> Optional.of(LB);
            default -> Optional.empty();
        };
    }
}
