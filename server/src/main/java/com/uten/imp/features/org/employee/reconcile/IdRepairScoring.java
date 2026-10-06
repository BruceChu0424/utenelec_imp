package com.uten.imp.features.org.employee.reconcile;

import java.util.Set;

/**
 * 证件号修复打分常量（方案 4.4.5，log10 似然），全项目只此一份，便于统一校准。
 *
 * <p>每个候选操作的基准分是其先验概率的对数：SUB 是 Verhoeff 1969 邮政实录里
 * 单字替换占全部单错误的份额再摊到 18 位 × 9 种换法；SWAP/INS/DEL 同理。
 * 证据惩罚直接从得分里扣，最后用 softmax10（含 {@link #OTHER} 兜底质量）归一成概率。
 */
public final class IdRepairScoring {

    /** 单字替换（含第 18 位）：log10(.79 / 18 / 9)。解出来、不被校验码验证。 */
    public static final double BASE_SUB = -2.31;
    /** 相邻两位对调：log10(.10 / 17)。对调必被校验码发现，所以是被验证的。 */
    public static final double BASE_SWAP = -2.23;
    /** 多打一位：log10(.10 / 180)。 */
    public static final double BASE_INS = -3.26;
    /** 少打一位：log10(.10 / 19)。删除后仍过校验是被验证的。 */
    public static final double BASE_DEL = -2.28;
    /** 去掉空格/横线等分隔符：不是录错，不扣分。 */
    public static final double BASE_NORMALIZE = 0.0;
    /** 确定性字符映射（×→X、O→0、I/L/|→1）：不是录错，不扣分。 */
    public static final double BASE_MAP_CHAR = 0.0;
    /** 15 位老证升 18 位：GB 11643 规定的确定性换算，不扣分。 */
    public static final double BASE_UPGRADE15 = 0.0;
    /** 用独立证据生日替换生日段：证据本身也可能错，小幅扣分。 */
    public static final double BASE_ANCHOR_BIRTH = -1.0;
    /** 单个未知字符由校验方程解出：解出来的必然过校验，等同单字替换。 */
    public static final double BASE_ERASE_SOLVED = -2.31;

    /** DEL 删掉的字符与相邻字符相同（双击重复）时加分。 */
    public static final double BONUS_DEL_REPEAT = 0.5;
    /** INS 在第 18 位补 'X'（丢末位 X）时加分。 */
    public static final double BONUS_INS_TAIL_X = 0.7;
    /** SUB 的 (旧,新) 数字对属于键盘/字形易混对时加分。 */
    public static final double BONUS_CONFUSABLE = 0.3;

    /** 证据生日与候选生日不一致。 */
    public static final double EVIDENCE_BIRTH_MISMATCH = -2.0;
    /** 证据性别与候选第 17 位奇偶不一致。 */
    public static final double EVIDENCE_GENDER_MISMATCH = -1.7;

    /** 「模型外/多处错误」的兜底质量，softmax 分母里始终含它。 */
    public static final double OTHER = -3.3;

    /** 评为「高」的概率门槛。 */
    public static final double P_HIGH = 0.90;
    /** 评为「中」的概率门槛。 */
    public static final double P_MEDIUM = 0.60;
    /** 「中」还要求比第二名（候选或 OTHER 取大）高出这么多倍。 */
    public static final double MARGIN_FACTOR = 3.0;

    /**
     * 键盘/字形易混数字对（两位十进制数，如 17 表示 1↔7）；08、02 按 8、2 存。
     * 两序皆算：1→7 和 7→1 同样加分。
     */
    private static final Set<Integer> CONFUSABLE_PAIRS =
            Set.of(17, 38, 56, 60, 8, 49, 27, 69, 14, 25, 36, 47, 58, 12, 23, 45, 78, 89, 2);

    private IdRepairScoring() {}

    /** (旧,新) 数字对是否属于易混对；非数字或相同不算。 */
    public static boolean confusablePair(int oldDigit, int newDigit) {
        if (oldDigit == newDigit || oldDigit < 0 || oldDigit > 9 || newDigit < 0 || newDigit > 9) {
            return false;
        }
        return CONFUSABLE_PAIRS.contains(oldDigit * 10 + newDigit)
                || CONFUSABLE_PAIRS.contains(newDigit * 10 + oldDigit);
    }
}
