package com.uten.imp.common.inventory;

import java.math.BigDecimal;
import java.util.Locale;
import java.util.Set;

/** The shared ADR-131 mass aliases; an unknown unit never implies a conversion. */
public final class PeriodicMaterialUnits {
    private static final Set<String> KILOGRAM_NAMES = Set.of("千克", "公斤", "kg", "kgs");
    private static final Set<String> GRAM_NAMES = Set.of("克", "g", "公克");
    private PeriodicMaterialUnits() { }

    public static BigDecimal gramsPerUnit(String unitName) {
        if (unitName == null) return null;
        String name = unitName.strip().toLowerCase(Locale.ROOT);
        if (KILOGRAM_NAMES.contains(name)) return BigDecimal.valueOf(1000);
        if (GRAM_NAMES.contains(name)) return BigDecimal.ONE;
        return null;
    }
}
