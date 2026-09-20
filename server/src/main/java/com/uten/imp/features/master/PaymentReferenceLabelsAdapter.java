package com.uten.imp.features.master;

import com.uten.imp.application.port.PaymentReferenceLabelsPort;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
@RequiredArgsConstructor
public class PaymentReferenceLabelsAdapter implements PaymentReferenceLabelsPort {
    private final EntityManager em;

    @Override
    @Transactional(readOnly = true)
    public Labels resolve(UUID accountId, UUID expenseStyleId) {
        if (accountId == null && expenseStyleId == null) return Labels.EMPTY;
        // Historical references retain their names even if the master was retired.
        // Select only the two labels, never account balances or finance configuration.
        Object[] row = (Object[]) em.createNativeQuery("""
                SELECT (SELECT concat_ws(' · ',NULLIF(btrim(code),''),NULLIF(btrim(name),''))
                        FROM accounts WHERE id=CAST(:account AS uuid)),
                       (SELECT concat_ws(' · ',NULLIF(btrim(code),''),NULLIF(btrim(name),''))
                        FROM payment_styles WHERE id=CAST(:style AS uuid))
                """).setParameter("account", accountId).setParameter("style", expenseStyleId).getSingleResult();
        return new Labels((String) row[0], (String) row[1]);
    }
}
