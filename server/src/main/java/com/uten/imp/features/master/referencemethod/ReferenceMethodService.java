package com.uten.imp.features.master.referencemethod;

import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/** Application entry point for settlement and finance payment-method dictionaries. */
@Service
@RequiredArgsConstructor
public class ReferenceMethodService {

    private final SettlementMethodRepository settlementMethods;
    private final FinancePaymentMethodRepository financeMethods;

    @Transactional(readOnly = true)
    public List<ReferenceMethodOption> settlementOptions() {
        return settlementMethods.findByStatusAndDeletedFalseOrderBySortOrderAscCodeAsc("使用")
                .stream()
                .map(method -> new ReferenceMethodOption(
                        method.getId(), method.getLegacyId(), method.getCode(), method.getLegacyCode(),
                        method.getName(), true))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<ReferenceMethodOption> financeOptions(String direction) {
        String normalized = direction == null ? "ANY" : direction.trim().toUpperCase();
        if (!List.of("ANY", "RECEIPT", "PAYMENT").contains(normalized)) normalized = "ANY";
        final String required = normalized;
        return financeMethods
                .findByLegacyNameConfirmedTrueAndStatusAndDeletedFalseOrderBySortOrderAscCodeAsc("使用")
                .stream()
                .filter(method -> required.equals("ANY")
                        || (required.equals("RECEIPT") && method.isReceipt())
                        || (required.equals("PAYMENT") && method.isPayment()))
                .map(method -> new ReferenceMethodOption(
                        method.getId(), method.getLegacyId(), method.getCode(), null,
                        method.getName(), method.isLegacyNameConfirmed()))
                .toList();
    }
}
