package com.uten.imp.features.sales.intake;

/**
 * 行级提醒(结果 lines[].warnings[]): {@code code} 给界面判断, {@code message} 是给销售看的大白话。
 */
record IntakeWarning(String code, String message) {

    static final String AMOUNT_MISMATCH = "AMOUNT_MISMATCH";
    static final String UNIT_NOT_PCS = "UNIT_NOT_PCS";
    static final String BUNDLE_LINE = "BUNDLE_LINE";
    static final String DUPLICATE_GOODS = "DUPLICATE_GOODS";
    static final String NO_LIST_PRICE = "NO_LIST_PRICE";
    static final String ABOVE_LIST = "ABOVE_LIST";
    /** 文件有单价, 但按人民币和按外币都说得通(折扣不填, 请人核对)。 */
    static final String AMBIGUOUS_CURRENCY = IntakePricing.AMBIGUOUS_CURRENCY;
    /** 文件有单价, 但算出来的折扣低于 3 折或单价不正常。 */
    static final String OUT_OF_RANGE = IntakePricing.OUT_OF_RANGE;
    /** 文件是外币, 财务还没维护参考汇率。 */
    static final String RATE_MISSING = IntakePricing.RATE_MISSING;
    /** 其他算不出折扣的情况(兜底)。 */
    static final String PRICE_CHECK = "PRICE_CHECK";
}
