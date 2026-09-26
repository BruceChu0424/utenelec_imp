package com.uten.imp.common.util;

import java.math.BigDecimal;

/** Additive JSON text properties preserve exact editable decimals alongside legacy numeric displays. */
public final class DecimalText {
    private DecimalText() { }
    /** 展示口径统一去尾随零："1000"而非"1000.0000"；stripTrailingZeros 可能出科学计数法，须 toPlainString 落回原文。 */
    public static String of(BigDecimal value) { return value==null ? null : value.stripTrailingZeros().toPlainString(); }
}
