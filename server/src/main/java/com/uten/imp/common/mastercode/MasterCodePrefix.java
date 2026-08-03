package com.uten.imp.common.mastercode;

/**
 * 主档编号前缀注册表：每个基础资料主档 → 2 位拼音首字母前缀。
 *
 * <p>格式 {@code [前缀][6位顺序号]}，如货品 {@code HP000001}。前缀取拼音首字母、便于业务识别；
 * 已与全部老库遗留 code 验证零碰撞（{@code ^前缀[0-9]{6}$} 计数为 0），故自动生成的新编号
 * 永不与历史数据冲突。
 *
 * <p>顺序号由 {@link MasterCodeService} 从 {@code master_code_sequences} 原子自增，
 * 单调递增、不复用；区别于单据号（{@link com.uten.imp.common.docnumber.DocNumberPrefix}，
 * 带 YYMM 月度），主档编号是永久标识，不带日期。
 *
 * @see MasterCodeService
 */
public enum MasterCodePrefix {
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

    /** 前缀，如 "HP"/"UT"。 */
    public String code() {
        return code;
    }

    /** 顺序号位数（左补零），默认 6；工号为 4（UT0001）。 */
    public int width() {
        return width;
    }
}
