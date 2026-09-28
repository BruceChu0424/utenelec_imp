package com.uten.imp.features.sales.quote.dto;

import jakarta.validation.constraints.Size;

/**
 * 报价状态动作请求(提交核价 / 撤回 / 重新修改 / 财务撤销确认)。expectedRevision = 页面看到的核价修订号,
 * 与当前不一致说明别人刚处理过, 按冲突拒绝; 撤回、重新修改、财务撤销确认必须带。reason 只用于说明。
 */
public record QuoteActionRequest(
        Integer expectedRevision,
        @Size(max = 500, message = "说明不能超过 500 个字符") String reason) {

    public QuoteActionRequest(Integer expectedRevision) {
        this(expectedRevision, null);
    }
}
