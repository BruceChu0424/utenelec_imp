package com.uten.imp.features.org.employee.reconcile;

/**
 * 人事核对提示文案目录：稳定的机器码 {@link #code()} 给程序和库存用，
 * {@link #message(String...)} 给人看。
 *
 * <p>硬约束（方案 ADR-154 §5）：任何文案绝不包含证件号本身，也不出现
 * 6 位以上连续数字——数据库 CHECK 约束会拒绝这样的字符串。带占位符的
 * 文案（目前只有 {@link #CLAIMED_BY_OTHER} 的 {name}、{until}）按出现
 * 顺序用参数依次填充。
 */
public enum ReconcileNotice {

    /** 证件号未填写。 */
    EMPTY("EMPTY", "证件号未填写"),

    /** 号码被脱敏（含 *），无法自动修复。 */
    MASKED("MASKED", "号码已脱敏，无法自动修复"),

    /** 存量号形如 15 位数字后接 000，是 Excel 把号码当数字截断的典型形状。 */
    EXCEL_TRUNCATED("EXCEL_TRUNCATED",
            "疑似被 Excel 截断，后三位已丢失，请把该列设为文本后重新导出或对照证件"),

    /** 首字母像护照或港澳台通行证的编号。 */
    TYPE_HINT_FOREIGN("TYPE_HINT_FOREIGN", "号码像护照或港澳台通行证，建议先核对证件类型"),

    /** 首位 9 的 18 位号按 GB 11643 校验通过但省级码不合法，是 2023 版外国人永居证的形状。 */
    TYPE_HINT_RESIDENT("TYPE_HINT_RESIDENT", "首位 9 的 18 位号可能是外国人永居证，请核对证件类型"),

    /** 18 位号的省级码无法确认。 */
    REGION_UNKNOWN("REGION_UNKNOWN", "地区码无法确认，请对照证件"),

    /** 第 15-17 位顺序码是 000，90 种填法都过校验，数学上无法唯一确定。 */
    SEQUENCE_ZERO("SEQUENCE_ZERO", "顺序码是 000，请对照证件"),

    /** 单步邻域内解不出，大概率不止一处错误。 */
    MULTIPLE_ERRORS("MULTIPLE_ERRORS", "不止一处错误，请对照证件"),

    /** 历史导入的证件密文解不开，只能人工重录。 */
    CIPHER_UNREADABLE("CIPHER_UNREADABLE", "证件密文无法解密，需人工重新录入"),

    /** 该员工绑定超级管理员账号，不能走批量更正（ADR-154 §3.6）。 */
    SUPER_ADMIN_BOUND("SUPER_ADMIN_BOUND", "该员工绑定超级管理员账号，请单独修改"),

    /** 存量号本身已通过 GB 11643 校验。 */
    ALREADY_VALID("ALREADY_VALID", "证件号已通过校验，无需核对"),

    /** 证件类型不是身份证，本引擎不自动修复。 */
    NOT_RESIDENT_ID("NOT_RESIDENT_ID", "证件类型不是身份证，本次不自动修复"),

    /** 该项正被别人认领处理；参数依次填 {name}、{until}。 */
    CLAIMED_BY_OTHER("CLAIMED_BY_OTHER", "此项正由 {name} 处理（认领至 {until}），请稍后再试"),

    /** 核对计划生成后此人档案被修改过，版本已过期。 */
    STALE_VERSION("STALE_VERSION", "计划生成后此人档案被修改过，请刷新核对"),

    /** 核对计划生成后该项值已被他人修改。 */
    STALE_VALUE("STALE_VALUE", "计划生成后此项已被他人修改"),

    /** 当前用户缺少「员工证件与联系方式修改」权限。 */
    NO_PERMISSION("NO_PERMISSION", "缺少「员工证件与联系方式修改」权限");

    private final String code;
    private final String template;

    ReconcileNotice(String code, String template) {
        this.code = code;
        this.template = template;
    }

    /** 稳定机器码，可以存库、对比。 */
    public String code() {
        return code;
    }

    /** 渲染人读文案；{xxx} 占位符按出现顺序依次用 args 填充，参数不足时保留原占位符。 */
    public String message(String... args) {
        String text = template;
        for (String arg : args) {
            int start = text.indexOf('{');
            int end = start < 0 ? -1 : text.indexOf('}', start);
            if (end < 0) {
                break;
            }
            text = text.substring(0, start) + arg + text.substring(end + 1);
        }
        return text;
    }
}
