package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.UUID;

/**
 * Single write path for encrypted employee identifiers and their deterministic
 * lookup derivatives.  Callers must never update an encrypted phone/identity
 * column without updating its HMAC and display mask in the same transaction.
 */
@Component
@RequiredArgsConstructor
public class EmployeePiiWriter {

    private final TxSessionVars tx;
    private final EmployeeSensitiveRepository sensitiveRepo;

    public void applyIdentity(
            EmployeeSensitive target,
            UUID employeeId,
            String idType,
            String idNumber) {
        if (idNumber == null || idNumber.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "证件号码不能为空");
        }
        String normalized = "身份证".equals(idType)
                ? IdCardUtil.normalize(idNumber)
                : idNumber.trim();
        if ("身份证".equals(idType) && !IdCardUtil.isValid(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "身份证号校验未通过");
        }
        String hash = tx.hmac(normalized);
        if (hash != null && sensitiveRepo.existsByIdCardHashAndEmployeeIdNot(hash, employeeId)) {
            throw new ApiException(ErrorCode.CONFLICT, "该身份证号已被其他员工使用");
        }
        target.setIdCardEnc(tx.encrypt(normalized));
        target.setIdCardLast4(IdCardUtil.last4(normalized));
        target.setIdCardHash(hash);
    }

    public void applyPhone(EmployeeSensitive target, String phone) {
        String normalized = ChinaMobileNumber.normalize(phone)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "中国大陆手机号格式不正确"));
        target.setPhoneEnc(tx.encrypt(normalized));
        target.setPhoneHash(tx.hmac(normalized));
    }

    // ===== V282 扩展加密字段（户籍/居住地址、邮箱、出生日期、婚姻/政治面貌、办公电话）=====
    // 均为单向加密（无查重 HMAC 需求）。tx.encrypt 对 null/空白返回 null，故传 null 即"不设/清空"。
    // 调用方按"非空才更新"语义自行决定是否调用（与身份证/手机一致）。

    public void applyHujiAddress(EmployeeSensitive target, String value) {
        target.setHujiAddressEnc(tx.encrypt(value));
    }

    public void applyResidenceAddress(EmployeeSensitive target, String value) {
        target.setResidenceAddressEnc(tx.encrypt(value));
    }

    public void applyEmail(EmployeeSensitive target, String value) {
        target.setEmailEnc(tx.encrypt(value));
    }

    public void applyMaritalStatus(EmployeeSensitive target, String value) {
        target.setMaritalStatusEnc(tx.encrypt(value));
    }

    public void applyPoliticalStatus(EmployeeSensitive target, String value) {
        target.setPoliticalStatusEnc(tx.encrypt(value));
    }

    public void applyOfficePhone(EmployeeSensitive target, String value) {
        target.setOfficePhoneEnc(tx.encrypt(value));
    }

    /** 出生日期加密为 ISO yyyy-MM-dd 字符串（解密端按 LocalDate.parse 还原）。 */
    public void applyBirthDate(EmployeeSensitive target, LocalDate birthDate) {
        target.setBirthDateEnc(birthDate == null ? null : tx.encrypt(birthDate.toString()));
    }
}
