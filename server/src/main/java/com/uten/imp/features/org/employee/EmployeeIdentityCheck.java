package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardProblem;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.features.org.employee.dto.IdNumberIssue;

import java.util.Set;

/**
 * 员工证件号码校验结果的唯一口径 (V807 {@code employee_sensitive.id_card_check})。
 *
 * <p>写入侧 {@link #classify}：写证件号密文时判定一次存成一列 (EmployeePiiWriter 与启动回填任务共用；
 * 回填任务解不开的密文存 {@link #UNREADABLE})；读取侧 {@link #issueOf}：员工详情、开号就绪检查、
 * 人事证件核对任务都只从这里拿结果，同一种存储值在各处给出同一句原因。规则只有 {@link IdCardUtil#check} 一份。
 */
public final class EmployeeIdentityCheck {

    /** 证件号码通过校验 (身份证通过 GB11643；其它证件只要不为空)。 */
    public static final String VALID = "valid";
    /** 历史资料导入，还没判定；启动回填任务处理。 */
    public static final String UNCHECKED = "unchecked";
    /**
     * 有证件号密文，但解密失败 (数据损坏，或换密钥后没配旧密钥)：启动回填任务存这个值，以后启动不再重试；
     * 人事重新登记号码时随新密文改写。员工详情读取时密文解不开，不管存的是什么也按这个值提醒。
     */
    public static final String UNREADABLE = "unreadable";

    public static final String ISSUE_MISSING = "missing";
    public static final String ISSUE_INVALID = "invalid";
    public static final String ISSUE_UNCHECKED = "unchecked";

    public static final String RESIDENT_ID = "身份证";
    /** employees.id_type 的 CHECK 取值 (V03)。 */
    public static final Set<String> ID_TYPES = Set.of("身份证", "护照", "港澳台通行证", "其他");

    static final String MISSING_REASON = "档案里没有证件号码";
    static final String UNCHECKED_REASON = "证件号码来自历史资料导入，系统还没有完成校验";
    /** {@link #UNREADABLE}：档案里有证件号码密文，但解密失败。 */
    static final String UNREADABLE_REASON = "档案里的证件号码读取不出来，系统无法校验，请人事对照证件重新登记";
    /** 库里出现不认识的问题码时的兜底 (CHECK 约束下不会发生)。 */
    static final String UNKNOWN_PROBLEM_REASON = "证件号码没有通过校验，请对照证件核对";

    /** 存储列 CHECK 允许的长度码最多 3 位。 */
    private static final int MAX_STORED_LENGTH = 999;

    private EmployeeIdentityCheck() {
    }

    /**
     * 写入时判定：返回 {@link #VALID} 或 {@link IdCardProblem} 的问题码。
     * 身份证按 {@link IdCardUtil#check}；其它证件号码不为空即 valid。
     */
    static String classify(String idType, String idNumber) {
        if (idNumber == null || idNumber.isBlank()) {
            return IdCardProblem.EMPTY;
        }
        if (!RESIDENT_ID.equals(idType)) {
            return VALID;
        }
        IdCardProblem problem = IdCardUtil.check(idNumber);
        if (problem == null) {
            return VALID;
        }
        String code = problem.code();
        if (code.startsWith(IdCardProblem.LENGTH_PREFIX)
                && code.length() - IdCardProblem.LENGTH_PREFIX.length() > 3) {
            return IdCardProblem.LENGTH_PREFIX + MAX_STORED_LENGTH;
        }
        return code;
    }

    /**
     * 读取侧：对外的证件问题；返回 null 表示不用人事处理。
     * {@link #UNREADABLE} 按「尚未校验」(前端只认 missing / invalid / unchecked 三种，确实也没法校验) 提醒，
     * 原因说明是号码读取不出来；不拦开号，开号时初始密码改为系统随机生成。
     *
     * @param hasCipher         档案里是否有证件号码密文
     * @param storedCheck       {@code employee_sensitive.id_card_check}；读取时顺带解密却解不开的地方传 {@link #UNREADABLE}
     * @param superAdminAccount 该员工是否绑定超级管理员账号 (人事改不了超管的证件，不能列成永远结不了的任务)
     */
    public static IdNumberIssue issueOf(boolean hasCipher, String storedCheck, boolean superAdminAccount) {
        if (superAdminAccount) {
            return null;
        }
        if (!hasCipher) {
            return new IdNumberIssue(ISSUE_MISSING, MISSING_REASON);
        }
        if (VALID.equals(storedCheck)) {
            return null;
        }
        if (storedCheck == null || UNCHECKED.equals(storedCheck)) {
            return new IdNumberIssue(ISSUE_UNCHECKED, UNCHECKED_REASON);
        }
        if (UNREADABLE.equals(storedCheck)) {
            return new IdNumberIssue(ISSUE_UNCHECKED, UNREADABLE_REASON);
        }
        IdCardProblem problem = IdCardProblem.fromCode(storedCheck);
        return new IdNumberIssue(ISSUE_INVALID,
                problem == null ? UNKNOWN_PROBLEM_REASON : problem.message());
    }
}
