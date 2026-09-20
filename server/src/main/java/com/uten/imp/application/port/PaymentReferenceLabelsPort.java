package com.uten.imp.application.port;

import java.util.UUID;

/** Historical display labels only; grants no account balance or master-data mutation access. */
public interface PaymentReferenceLabelsPort {
    Labels resolve(UUID accountId, UUID expenseStyleId);

    record Labels(String account, String expenseStyle) {
        public static final Labels EMPTY = new Labels(null, null);
    }
}
