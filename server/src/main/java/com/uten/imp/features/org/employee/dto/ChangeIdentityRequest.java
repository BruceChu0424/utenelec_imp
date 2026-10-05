package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** 修改证件信息 (人事核对证件后修正)：证件类型和号码一起改；身份证号严格校验。 */
public record ChangeIdentityRequest(
        @NotBlank(message = "证件类型不能为空")
        @Size(max = 20)
        String idType,
        @NotBlank(message = "证件号码不能为空")
        @Size(max = 64, message = "证件号码不能超过64位")
        String idNumber) {}
