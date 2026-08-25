package com.uten.imp.features.admin.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 账号列表项（HR 管理账号用）。 */
@Getter
@AllArgsConstructor
public class UserSummary {
    private UUID id;
    private UUID employeeId;
    private String loginAccount;
    private String employeeName;
    private String employeeCode;
    /** 绑定员工的当前任职状态；仅账号绑定缺失时为NULL。 */
    private String employeeStatus;
    /** 服务端统一在册口径，UI不得复制状态枚举推导。 */
    private boolean currentEmployee;
    private UUID departmentId;
    private String departmentName;
    private String status;
    private boolean mustChangePassword;
    private OffsetDateTime lastLoginAt;
    private List<String> roles;
    /** 是否授权云端(外网)访问；权限页「云端访问」开关据此回显当前状态。 */
    private boolean remoteAccess;
    /** 管理员设置的临时密码有效期截止（V297）；NULL = 无临时密码或不受有效期限制。 */
    private OffsetDateTime tempPasswordExpiresAt;
}
