package com.uten.imp.common.export;

/**
 * 加密导出请求体：仅含密码（密码走 body，不入 URL/query/日志；行级过滤与排序仍走 query 参数）。
 */
public record ExportPasswordRequest(String password) {
}
