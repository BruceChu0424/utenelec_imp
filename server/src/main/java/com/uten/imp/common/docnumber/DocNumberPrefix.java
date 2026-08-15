package com.uten.imp.common.docnumber;

/**
 * 单据号前缀源码契约：每个单据类型 → 唯一的 2 位业务助记前缀。
 *
 * <p>V279 起新号格式为 {@code [前缀][YYYYMMDD][6位日流水]}；老库
 * {@code [前缀][YYMM][4位顺序号]} 原样保留且终身占号。运行时前缀由数据库命名空间注册表解析，
 * 本枚举名是稳定 namespace key。前缀和完整单据号均由 V279 数据库注册表全局、终身占用，
 * 软删或作废也不得把旧号分配给另一业务身份。
 *
 * <p>单据号只用于员工识别、搜索、打印和历史快照；关联、权限与幂等始终使用 UUID。
 * 制单人工号不拼入号码，制单人由员工 UUID、姓名快照和审计记录表达。
 *
 * <p><b>CJ 冲突消歧</b>：老库 CJ 被采购收货与仓库产成品进仓共用。新系统：
 * <ul>
 *   <li>采购收货保留 {@code CJ}（量大、外部引用多）；</li>
 *   <li>仓库产成品进仓改用新前缀 {@code CR}（C=产成品族配 CC 出，R=入）；老 CJ 数据原号保留。</li>
 * </ul>
 *
 * <p>销售订单固定 {@code XD}；{@code XS} 已永久属于财务收款，不能复用。
 * 无老库数据的新单据新铸前缀包括销售报价 {@code XB}、委外材料退 {@code ER}、
 * 委外损耗 {@code EW}、仓库损耗 {@code QW} 与生产子计划 {@code SZ}。
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
    STOCK_WASTE("QW"),
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
    FIXED_ASSET("FA"),
    DEFERRED_EXPENSE("DA"),
    // 生产
    PRODUCTION_PLAN("SJ"),
    PRODUCTION_SUBPLAN("SZ"),
    PRODUCTION_DAILY_REPORT("SR"),
    // 研发
    RD_TASK("RD");

    private final String code;

    DocNumberPrefix(String code) {
        this.code = code;
    }

    /** 2 位源码契约镜像，如 "CD"；运行时仍以 V279 数据库注册表为权威。 */
    public String code() {
        return code;
    }
}
