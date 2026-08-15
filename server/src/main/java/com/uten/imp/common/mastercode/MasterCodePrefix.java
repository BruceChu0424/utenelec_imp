package com.uten.imp.common.mastercode;

/**
 * 固定流水编号前缀注册表：业务主档通常使用 2 位助记前缀，系统号可使用
 * 独立的 1–2 位前缀。
 *
 * <p>格式 {@code [前缀][固定位数顺序号]}，如货品 {@code HP000001}、
 * 执行分段 {@code ZX00000001}。主档前缀便于业务识别；
 * V279 全局预约表会跳过任何历史跨域占号，并永久保留每个曾使用的规范化编号。
 *
 * <p>顺序号由 {@link MasterCodeService} 从 {@code master_code_sequences} 原子自增，
 * 单调递增、不复用；区别于按上海业务日归零的单据号
 * （{@link com.uten.imp.common.docnumber.DocNumberPrefix}），主档显示编码不带日期。
 * 关联身份始终是 UUID；显示编码可以受控修改，但旧值永远不能分配给另一身份。
 *
 * @see MasterCodeService
 */
public enum MasterCodePrefix {
    VISITOR("V", 8),        // Visitor number; never derives from a phone number.
    PRODUCTION_EXECUTION_SEGMENT("ZX", 8), // Production execution segment/barcode.
    GOODS("HP"),          // 货品
    MOULD("MJ"),          // 模具
    CLIENT("KH"),         // 客户
    SUPPLIER("GY"),       // 供应商
    COLOR("YS"),          // 颜色
    UNIT("DW"),           // 单位
    CURRENCY("BZ"),       // 币种
    WAREHOUSE("WH"),      // 仓库
    ACCOUNT("ZH"),        // 账户
    PAYMENT_STYLE("SK"),  // 收付款类别
    CATEGORY("FL"),       // 货品/物料分类（material_categories）
    MOULD_CATEGORY("MF"),    // 模具分类（mould_categories）
    CLIENT_CATEGORY("KF"),   // 客户分类（client_categories）
    SUPPLIER_CATEGORY("GF"), // 供应商分类（supplier_categories）
    EMPLOYEE("UT", 4),       // 员工工号（UT 前缀 + 4 位顺序号，如 UT0001）
    POSITION("ZW");          // 自动新增岗位（ZW 前缀 + 6 位顺序号）

    private final String code;
    private final int width;

    MasterCodePrefix(String code) {
        this(code, 6);
    }

    MasterCodePrefix(String code, int width) {
        this.code = code;
        this.width = width;
    }

    /** 前缀，如 "HP"/"UT"/"V"。 */
    public String code() {
        return code;
    }

    /** 顺序号固定位数（左补零且禁止溢出），默认 6。 */
    public int width() {
        return width;
    }
}
