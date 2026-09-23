package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.exc.MismatchedInputException;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import org.springframework.core.type.filter.AssignableTypeFilter;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-112 契约: 保存请求不带金额。标记了 {@link ServerDerivedAmounts} 的 DTO 不声明金额字段,
 * 请求体带金额字段被拒(Spring 转 400), 其它 DTO 的未知字段仍按全局口径忽略。
 */
class ServerDerivedAmountsContractTest {

    /** 全部带货品金额的保存行与资金单据保存请求(金额由服务端派生)。 */
    private static final List<String> REQUIRED = List.of(
            "com.uten.imp.features.purchase.order.dto.OrderItemLine",
            "com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine",
            "com.uten.imp.features.purchase.request.dto.RequestItemLine",
            "com.uten.imp.features.purchase.ret.dto.ReturnItemLine",
            "com.uten.imp.features.sales.order.dto.OrderItemLine",
            "com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemLine",
            "com.uten.imp.features.sales.quote.dto.QuoteItemLine",
            "com.uten.imp.features.sales.ret.dto.ReturnItemLine",
            "com.uten.imp.features.sales.shipment.dto.ShipmentItemLine",
            "com.uten.imp.features.subcontract.application.dto.ApplicationItemLine",
            "com.uten.imp.features.subcontract.inquiry.dto.InquiryItemLine",
            "com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine",
            "com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine",
            "com.uten.imp.features.subcontract.order.dto.OrderItemLine",
            "com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine",
            "com.uten.imp.features.subcontract.ret.dto.ReturnItemLine",
            "com.uten.imp.features.subcontract.waste.dto.WasteItemLine",
            "com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferLineInput",
            "com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest",
            "com.uten.imp.features.finance.expense.dto.FinanceExpenseItemInput",
            "com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest",
            "com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemInput",
            "com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest",
            "com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput",
            "com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest",
            "com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput",
            "com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest");

    /** 资金单据的实际金额原文(银行/发票事实)仍由用户录入, 只有派生的本币与表头合计被禁止。 */
    private static final Set<String> ACTUAL_AMOUNT_INPUTS = Set.of(
            "FinanceBankTransferLineInput", "FinanceExpenseItemInput", "FinanceOtherIncomeItemInput",
            "FinancePaymentLineInput", "FinanceReceiptLineInput", "FinancePaymentSaveRequest",
            "FinanceReceiptSaveRequest");

    @Test
    void everySaveRequestIsMarkedAndDeclaresNoDerivedAmount() throws Exception {
        var scanner = new ClassPathScanningCandidateComponentProvider(false);
        scanner.addIncludeFilter(new AssignableTypeFilter(ServerDerivedAmounts.class));
        Set<String> marked = new TreeSet<>();
        scanner.findCandidateComponents("com.uten.imp").forEach(bean -> marked.add(bean.getBeanClassName()));
        assertThat(marked).containsAll(REQUIRED);

        List<String> violations = new ArrayList<>();
        for (String name : marked) {
            Class<?> type = Class.forName(name);
            for (Class<?> current = type; current != null && current != Object.class; current = current.getSuperclass()) {
                for (Field field : current.getDeclaredFields()) {
                    boolean actualInput = "amountOriginal".equals(field.getName())
                            && ACTUAL_AMOUNT_INPUTS.contains(type.getSimpleName());
                    if (ServerDerivedAmounts.CLIENT_FORBIDDEN_FIELDS.contains(field.getName()) && !actualInput) {
                        violations.add(type.getName() + "." + field.getName());
                    }
                }
            }
        }
        assertThat(violations).as("金额只由服务端派生, 保存请求不得声明金额字段").isEmpty();
    }

    @Test
    void bodiesCarryingAmountsAreRejectedWhileOtherUnknownFieldsStayIgnored() throws Exception {
        ObjectMapper mapper = new ObjectMapper()
                .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .registerModule(new ServerDerivedAmountsModule());
        Class<?> shipmentLine = Class.forName("com.uten.imp.features.sales.shipment.dto.ShipmentItemLine");
        Class<?> receiptLine = Class.forName("com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput");

        assertThatThrownBy(() -> mapper.readValue("{\"qty\":1,\"amountOriginal\":999999}", shipmentLine))
                .isInstanceOf(MismatchedInputException.class)
                .hasMessageContaining("金额由系统按数量、单价和汇率计算");
        assertThatThrownBy(() -> mapper.readValue("{\"qty\":1,\"costAmount\":1}", shipmentLine))
                .isInstanceOf(MismatchedInputException.class);
        assertThatThrownBy(() -> mapper.readValue("{\"amountOriginal\":1,\"amountLocal\":7}", receiptLine))
                .isInstanceOf(MismatchedInputException.class);
        // 派生值(汇兑差额、税额、退货金额)同样只由服务端算: 请求带了直接拒绝, 不再静默忽略或原样落库。
        assertThatThrownBy(() -> mapper.readValue("{\"amountOriginal\":1,\"exchangeDiff\":-8888}", receiptLine))
                .isInstanceOf(MismatchedInputException.class);
        assertThatThrownBy(() -> mapper.readValue("{\"qty\":1,\"taxAmount\":1}",
                Class.forName("com.uten.imp.features.sales.order.dto.OrderItemLine")))
                .isInstanceOf(MismatchedInputException.class);
        assertThatThrownBy(() -> mapper.readValue("{\"qty\":1,\"returnAmount\":1}",
                Class.forName("com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine")))
                .isInstanceOf(MismatchedInputException.class);

        assertThat(mapper.readValue("{\"qty\":1,\"someDisplayOnlyField\":\"x\"}", shipmentLine)).isNotNull();
        assertThat(mapper.readValue("{\"amountOriginal\":1}", receiptLine)).isNotNull();
    }
}
