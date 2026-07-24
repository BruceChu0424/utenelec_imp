package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.AuditableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 员工敏感 PII（pgcrypto 加密：身份证/手机/银行）。主键 = employee_id（与 Employee 1:1）。
 * 列中存储的是密文；明文仅由 service 解密后按角色脱敏返回。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_sensitive")
public class EmployeeSensitive extends AuditableEntity {

    @Id
    @Column(name = "employee_id")
    private UUID employeeId;

    @Column(name = "id_card_enc", nullable = false)
    private String idCardEnc;

    @Column(name = "id_card_last4")
    private String idCardLast4;

    @Column(name = "id_card_hash")
    private String idCardHash;

    @Column(name = "phone_enc", nullable = false)
    private String phoneEnc;

    @Column(name = "phone_hash")
    private String phoneHash;

    @Column(name = "bank_account_enc")
    private String bankAccountEnc;

    @Column(name = "bank_branch_enc")
    private String bankBranchEnc;
}
