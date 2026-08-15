package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Set;

/**
 * 个人信息修改字段策略（前端 UX 与后端权威校验共用同一份白名单）。
 * <ul>
 *   <li>{@link #DIRECT_EDIT}：员工改 → 立即生效</li>
 *   <li>{@link #REQUIRES_REVIEW}：员工改 → 走 HR 审批</li>
 *   <li>{@link #HR_ONLY}：员工页可读，无编辑入口</li>
 * </ul>
 *
 * <p>后端在 {@link #assertSelfEditable(String)} 校验；前端在 form policy 渲染。
 * 单一来源：调整字段策略只改本文件。
 */
public final class ProfileFieldPolicy {

    /** 字段机器码 = 提交 / 审批 / 应用的全链路识别符。 */
    public static final class Field {
        public static final String FULL_NAME = "fullName";
        public static final String GENDER = "gender";
        public static final String BIRTH_DATE = "birthDate";
        public static final String ETHNICITY = "ethnicity";
        public static final String POLITICAL_STATUS = "politicalStatus";
        public static final String MARITAL_STATUS = "maritalStatus";
        public static final String HUJI_ADDRESS = "hujiAddress";
        public static final String RESIDENCE_ADDRESS = "residenceAddress";
        public static final String PHONE = "phone";
        public static final String OFFICE_PHONE = "officePhone";
        public static final String EMAIL = "email";
        public static final String SEAT_NO = "seatNo";
        public static final String WORK_LOCATION = "workLocation";
        // 紧急联系人：按数组下标编码，如 emergencyContact.0.name / emergencyContact.0.phone
        public static final String EMERGENCY_CONTACT_PREFIX = "emergencyContact.";
        // 敏感 PII（HR 专属）：idCard / bankAccount / bankBranch / 薪资 — 不允许员工自助申请
        public static final String ID_CARD = "idCard";
        public static final String BANK_ACCOUNT = "bankAccount";
        public static final String BANK_BRANCH = "bankBranch";
        // HR 专属（组织 / 用工 / 状态）
        public static final String DEPARTMENT = "department";
        public static final String POSITION = "position";
        public static final String SUPERVISOR = "supervisor";
        public static final String HIRE_DATE = "hireDate";
        public static final String STATUS = "status";
        public static final String EMPLOYMENT_TYPE = "employmentType";
    }

    public static final class Group {
        public static final String IDENTITY = "identity";
        public static final String CONTACT = "contact";
        public static final String ADDRESS = "address";
        public static final String EMERGENCY = "emergency";
        public static final String COMPENSATION = "compensation";
        public static final String ORG = "org";
    }

    /** 直改字段（提交即生效）。 */
    public static final Set<String> DIRECT_EDIT = Set.of(
            Field.ETHNICITY,
            Field.POLITICAL_STATUS,
            Field.MARITAL_STATUS,
            Field.RESIDENCE_ADDRESS,
            Field.OFFICE_PHONE,
            Field.EMAIL,
            Field.SEAT_NO
    );

    /** 需审核字段（生成申请，HR 通过后合并到 Employee）。
     *  紧急联系人按 emergencyContact.N.xxx 编码，由 isEmergencyContactSubfield 覆盖，不在此枚举。 */
    public static final Set<String> REQUIRES_REVIEW = Set.of(
            Field.FULL_NAME,
            Field.HUJI_ADDRESS,
            Field.PHONE
    );

    /** HR 专属（员工不可自助申请；服务端拒绝并抛 422）。 */
    public static final Set<String> HR_ONLY = Set.of(
            Field.GENDER, Field.BIRTH_DATE,
            Field.WORK_LOCATION,
            Field.ID_CARD, Field.BANK_ACCOUNT, Field.BANK_BRANCH,
            Field.DEPARTMENT, Field.POSITION, Field.SUPERVISOR,
            Field.HIRE_DATE, Field.STATUS, Field.EMPLOYMENT_TYPE
    );

    /**
     * 校验字段是否允许员工自助修改；不允许则抛 {@link ApiException}。
     */
    public static void assertSelfEditable(String fieldCode) {
        if (fieldCode == null || fieldCode.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "字段不能为空");
        }
        if (isHrOnly(fieldCode)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "该字段需联系 HR 修改：" + fieldCode);
        }
        if (!DIRECT_EDIT.contains(fieldCode)
                && !REQUIRES_REVIEW.contains(fieldCode)
                && !isEmergencyContactSubfield(fieldCode)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知字段：" + fieldCode);
        }
    }

    public static boolean isDirectEdit(String fieldCode) {
        return DIRECT_EDIT.contains(fieldCode);
    }

    public static boolean isRequiresReview(String fieldCode) {
        return REQUIRES_REVIEW.contains(fieldCode) || isEmergencyContactSubfield(fieldCode);
    }

    /**
     * Whether the immutable review snapshot itself must be encrypted at rest.
     *
     * <p>This is deliberately narrower than "requires review": a full name is
     * reviewable but remains an ordinary business identity snapshot, while a
     * phone, household address, or any emergency-contact snapshot contains
     * personal data that must not be copied into {@code profile_change_requests}
     * as plaintext.</p>
     */
    public static boolean requiresEncryptedSnapshot(String fieldCode) {
        return Field.PHONE.equals(fieldCode)
                || Field.HUJI_ADDRESS.equals(fieldCode)
                || isEmergencyContactSubfield(fieldCode);
    }

    public static boolean isHrOnly(String fieldCode) {
        return HR_ONLY.contains(fieldCode);
    }

    public static boolean isEmergencyContactSubfield(String fieldCode) {
        return fieldCode != null && fieldCode.startsWith(Field.EMERGENCY_CONTACT_PREFIX);
    }

    /** 紧急联系人数组下标（0/1/2…）；非法时 -1。 */
    public static int emergencyContactIndex(String fieldCode) {
        if (!isEmergencyContactSubfield(fieldCode)) return -1;
        String tail = fieldCode.substring(Field.EMERGENCY_CONTACT_PREFIX.length());
        int dot = tail.indexOf('.');
        if (dot <= 0) return -1;
        try {
            return Integer.parseInt(tail.substring(0, dot));
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    public static String emergencyContactSubfield(String fieldCode) {
        if (!isEmergencyContactSubfield(fieldCode)) return null;
        String tail = fieldCode.substring(Field.EMERGENCY_CONTACT_PREFIX.length());
        int dot = tail.indexOf('.');
        return dot > 0 ? tail.substring(dot + 1) : null;
    }

    public static String groupOf(String fieldCode) {
        if (fieldCode == null) return Group.IDENTITY;
        if (isEmergencyContactSubfield(fieldCode)) return Group.EMERGENCY;
        return switch (fieldCode) {
            case Field.FULL_NAME, Field.GENDER, Field.BIRTH_DATE,
                 Field.ETHNICITY, Field.POLITICAL_STATUS, Field.MARITAL_STATUS,
                 Field.ID_CARD -> Group.IDENTITY;
            case Field.PHONE, Field.OFFICE_PHONE, Field.EMAIL -> Group.CONTACT;
            case Field.HUJI_ADDRESS, Field.RESIDENCE_ADDRESS, Field.WORK_LOCATION, Field.SEAT_NO -> Group.ADDRESS;
            case Field.BANK_ACCOUNT, Field.BANK_BRANCH -> Group.COMPENSATION;
            default -> Group.ORG;
        };
    }

    private ProfileFieldPolicy() {}
}
