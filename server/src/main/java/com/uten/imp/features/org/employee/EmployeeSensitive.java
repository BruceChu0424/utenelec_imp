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
 * 列中存储的是密文；明文仅由 service 解密后按 {@code employee:pii:view} 决定返回或脱敏。
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

    // V286: bootstrap/legacy employees can have extension ciphertext before
    // primary identity/mobile enrollment. Business services still require
    // both values before provisioning a normal employee login.
    @Column(name = "id_card_enc")
    private String idCardEnc;

    @Column(name = "id_card_last4")
    private String idCardLast4;

    @Column(name = "id_card_hash")
    private String idCardHash;

    @Column(name = "phone_enc")
    private String phoneEnc;

    @Column(name = "phone_hash")
    private String phoneHash;

    @Column(name = "bank_account_enc")
    private String bankAccountEnc;

    @Column(name = "bank_branch_enc")
    private String bankBranchEnc;

    // V282 扩展：户籍/居住地址、邮箱、出生日期(ISO yyyy-MM-dd)、婚姻/政治面貌、办公电话。
    // 与 id_card/phone 同表同密钥（pgcrypto）；明文仅 service 解密后按权限点返回或脱敏。

    @Column(name = "huji_address_enc")
    private String hujiAddressEnc;

    @Column(name = "residence_address_enc")
    private String residenceAddressEnc;

    @Column(name = "email_enc")
    private String emailEnc;

    @Column(name = "birth_date_enc")
    private String birthDateEnc;

    @Column(name = "marital_status_enc")
    private String maritalStatusEnc;

    @Column(name = "political_status_enc")
    private String politicalStatusEnc;

    @Column(name = "office_phone_enc")
    private String officePhoneEnc;
}
