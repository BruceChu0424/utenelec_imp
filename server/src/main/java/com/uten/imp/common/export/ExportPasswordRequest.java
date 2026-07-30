package com.uten.imp.common.export;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 加密导出请求体：仅含密码（密码走 body，不入 URL/query/日志；行级过滤与排序仍走 query 参数）。
 */
public record ExportPasswordRequest(
        @NotBlank(message = "导出密码不能为空")
        @Size(min = 6, max = 128, message = "导出密码长度必须为 6-128 位")
        String password) {
}
