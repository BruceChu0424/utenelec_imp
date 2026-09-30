package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.*;

/** Applicant annotations are draft data, not a second expense amount authority. */
@Configuration
@RequiredArgsConstructor
public class ExpensePlatformColumnResources {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final ExpenseClaimService claims;
    @Bean PlatformColumnResourceAdapter expenseClaimFields() { return resource(false); }
    @Bean PlatformColumnResourceAdapter expenseItemFields() {
        return resource(true).documentRows("SELECT id FROM expense_claim_items WHERE claim_id=:document");
    }
    private DocumentPlatformColumnAdapter resource(boolean lines) {
        return new DocumentPlatformColumnAdapter(lines ? "expense_claim_item" : "expense_claim",
                lines ? "报销明细" : "报销单", current, em, json,
                Set.of("expense:apply", "expense:approve", "expense:pay"), Set.of("expense:apply"),
                Set.of("expense:apply", "expense:approve", "expense:pay"), ExpenseClaim.class,
                lines ? "SELECT id, claim_id FROM expense_claim_items WHERE id IN (:ids)" : null,
                claims::detail, (id, header) -> DocumentPlatformColumnAdapter.draft(header)
                        && current.employeeId().filter(employee -> employee.equals(
                            DocumentPlatformColumnAdapter.uuid(header, "applicantId"))).isPresent(),
                List.of(new FactDefinition(lines ? "amount" : "totalAmount", "报销金额", true)))
                .documentCreateAuthorities(Set.of("expense:apply"));
    }
}
