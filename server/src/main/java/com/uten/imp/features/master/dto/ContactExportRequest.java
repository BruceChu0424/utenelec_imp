package com.uten.imp.features.master.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;

/**
 * 客户/供应商导出请求体: 导出密码 + 敏感检索值 (关键字、手机/电话/银行账号筛选)。
 * 两者都只走请求体, 不进入 URL、查询参数或访问日志; 其余筛选与排序仍走查询串。
 */
public record ContactExportRequest(
        @Size(max = 128, message = "导出密码长度不能超过 128 位") String password,
        @Valid ContactSensitiveFilter sensitiveFilter) {

    public ContactSensitiveFilter sensitive() {
        return ContactSensitiveFilter.orNone(sensitiveFilter);
    }
}
