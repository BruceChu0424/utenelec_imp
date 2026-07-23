package com.uten.imp.features.rbac.dto;

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
    private String loginAccount;
    private String employeeName;
    private String employeeCode;
    private String status;
    private boolean mustChangePassword;
    private OffsetDateTime lastLoginAt;
    private List<String> roles;
}
