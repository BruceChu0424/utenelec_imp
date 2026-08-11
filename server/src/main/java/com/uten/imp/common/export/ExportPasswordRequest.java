package com.uten.imp.common.export;

import jakarta.validation.constraints.Size;

/**
 * 表格导出请求体。密码只通过请求体传输，不进入 URL、查询参数或日志。
 *
 * <p>密码为空时导出普通工作簿；提供密码时对工作簿加密。业务允许弱密码，因此这里只限制
 * 最大长度，避免无界请求占用资源。
 */
public record ExportPasswordRequest(
        @Size(max = 128, message = "导出密码长度不能超过 128 位")
        String password) {
}
