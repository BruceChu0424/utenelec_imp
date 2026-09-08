package com.uten.imp.common.util;

import java.math.BigDecimal;

/** Additive JSON text properties preserve exact editable decimals alongside legacy numeric displays. */
public final class DecimalText {
    private DecimalText() { }
    public static String of(BigDecimal value) { return value==null ? null : value.toPlainString(); }
}
