package com.uten.imp.features.sales.intake;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 识别任务参数: {@code docType}(quote|order, 必填)、{@code clientId}(已选客户, 可选)、{@code docId}(正在编辑的草稿, 可选)、
 * {@code sheet}(指定工作表序号 0-7, 可选; 界面「也识别其他工作表」时用)。不认识的参数一律拒绝。
 */
record IntakeParams(String docType, UUID clientId, UUID docId, Integer sheetIndex) {

    static final String QUOTE = "quote";
    static final String ORDER = "order";
    private static final Set<String> KNOWN = Set.of("docType", "clientId", "docId", "sheet");

    static IntakeParams parse(Map<String, String> params) {
        Map<String, String> p = params == null ? Map.of() : params;
        for (String key : p.keySet()) {
            if (!KNOWN.contains(key)) {
                throw bad("不支持的参数");
            }
        }
        String docType = p.get("docType");
        if (!QUOTE.equals(docType) && !ORDER.equals(docType)) {
            throw bad("请说明是报价单还是订货单");
        }
        UUID clientId = uuid(p.get("clientId"));
        UUID docId = uuid(p.get("docId"));
        Integer sheet = null;
        String sheetText = p.get("sheet");
        if (sheetText != null && !sheetText.isBlank()) {
            try {
                sheet = Integer.parseInt(sheetText.strip());
            } catch (NumberFormatException e) {
                throw bad("工作表序号不正确");
            }
            if (sheet < 0 || sheet > 63) {
                throw bad("工作表序号不正确");
            }
        }
        return new IntakeParams(docType, clientId, docId, sheet);
    }

    boolean isOrder() {
        return ORDER.equals(docType);
    }

    private static UUID uuid(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        try {
            return UUID.fromString(value.strip());
        } catch (IllegalArgumentException e) {
            throw bad("参数格式不正确");
        }
    }

    private static ApiException bad(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
