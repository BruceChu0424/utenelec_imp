package com.uten.imp.common.docnumber;

/**
 * 单据号前缀注册表：每个单据类型 → 2 位前缀。
 *
 * <p>沿用老库 {@code [前缀][YYMM][4位顺序号]} 格式（老用户熟悉、迁移数据兼容）。
 *
 * <p><b>CJ 冲突消歧</b>：老库 CJ 被采购收货与仓库产成品进仓共用。新系统：
 * <ul>
 *   <li>采购收货保留 {@code CJ}（量大、外部引用多）；</li>
 *   <li>仓库产成品进仓改用新前缀 {@code CR}（C=产成品族配 CC 出，R=入）；老 CJ 数据原号保留。</li>
 * </ul>
 *
 * <p>无老库数据的新单据新铸前缀：销售报价 {@code XB}、委外材料退 {@code ER}、委外损耗 {@code EW}。
 *
 * @see DocNumberService
 */
public enum DocNumberPrefix {
    // 销售
    SALES_ORDER("XD"),
    SALES_SHIPMENT("XC"),
    SALES_OTHER_SHIPMENT("OC"),
    SALES_RETURN("XT"),
    SALES_QUOTE("XB"),
    // 采购
    PURCHASE_REQUEST("CS"),
    PURCHASE_ORDER("CD"),
    PURCHASE_RECEIPT("CJ"),
    PURCHASE_RETURN("CT"),
    // 仓库 stock_documents（按 doc_type）
    STOCK_TRANSFER("CB"),
    STOCK_OTHER_IN("QR"),
    STOCK_OTHER_OUT("QC"),
    STOCK_DRAW("SL"),
    STOCK_WDRAW("ST"),
    STOCK_FINISHED_OUT("CC"),
    STOCK_FINISHED_IN("CR"),
    STOCK_CHECK("PQ"),
    // 委外
    SUB_INQUIRY("EA"),
    SUB_APPLICATION("EB"),
    SUB_ORDER("EO"),
    SUB_MATERIAL_ISSUE("EC"),
    SUB_RECEIPT("EJ"),
    SUB_RETURN("ET"),
    SUB_MATERIAL_RETURN("ER"),
    SUB_WASTE("EW"),
    // 钱流
    FIN_RECEIPT("XS"),
    FIN_PAYMENT("CF"),
    FIN_EXPENSE("YF"),
    FIN_OTHER_INCOME("QS"),
    FIN_BANK_TRANSFER("YC"),
    // 生产
    PRODUCTION_PLAN("SJ"),
    PRODUCTION_DAILY_REPORT("SR");

    private final String code;

    DocNumberPrefix(String code) {
        this.code = code;
    }

    /** 2 位前缀，如 "CD"。 */
    public String code() {
        return code;
    }
}
