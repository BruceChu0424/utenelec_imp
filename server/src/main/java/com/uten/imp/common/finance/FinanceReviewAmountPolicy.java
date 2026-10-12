package com.uten.imp.common.finance;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.ReviewAmountEdit;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

/** Review changes input money, never accepts derived totals or source identities from a client. */
public final class FinanceReviewAmountPolicy {
    private FinanceReviewAmountPolicy() {}

    public static void requireEdits(List<ReviewAmountEdit> edits) {
        if (edits == null || edits.isEmpty() || edits.size() > 500) {
            throw invalid("请提供 1 至 500 行财务修改");
        }
        HashSet<UUID> seen = new HashSet<>();
        for (ReviewAmountEdit edit : edits) {
            if (edit == null || edit.itemId() == null || !seen.add(edit.itemId())) {
                throw invalid("财务修改明细身份缺失或重复");
            }
            if ((edit.price() == null) == (edit.totalAmountInput() == null)) {
                throw invalid("每行只能填写单价或总金额其中一项");
            }
            BigDecimal input = edit.price() == null ? MoneyPolicy.totalAmountInput(edit.totalAmountInput())
                    : FinancialExactAmount.unitPrice(edit.price(), "财务核改单价");
            if (input.signum() < 0) throw invalid("财务核改金额不能为负数");
        }
    }

    public static BigDecimal price(ReviewAmountEdit edit, BigDecimal quantity) {
        return edit.totalAmountInput() == null ? FinancialExactAmount.unitPrice(edit.price(), "财务核改单价")
                : MoneyPolicy.referenceUnitPrice(edit.totalAmountInput(), quantity);
    }

    public static void requireSamePricingMode(ReviewAmountEdit edit, BigDecimal previousTotalInput) {
        if ((previousTotalInput != null) != (edit.totalAmountInput() != null)) {
            throw invalid("审核修改须保持原计价方式，按总金额计价的行请修改总金额");
        }
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
