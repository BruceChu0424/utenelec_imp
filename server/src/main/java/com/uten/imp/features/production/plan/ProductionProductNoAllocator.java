package com.uten.imp.features.production.plan;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.HashSet;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Allocates a readable production-plan line number under the plan's stable UUID owner.
 *
 * <p>The generated form is {@code <plan bill no>-NNN}. The V279 database allocator
 * advances a per-plan counter and claims the global lifetime reservation in one call.
 * Java deliberately does not reproduce or write the registry tables itself.</p>
 *
 * <p>Draft edits rebuild item UUIDs, so the reservation owner is the plan UUID. An
 * existing number may therefore be reused by the same plan but never by another plan.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionProductNoAllocator {

    private static final String ALLOCATE_SQL =
            "SELECT fn_allocate_production_product_no(?)";

    private final JdbcTemplate jdbc;

    @Transactional(propagation = Propagation.MANDATORY)
    public String allocate(
            UUID planId,
            Set<String> excludedNormalizedIdentifiers) {
        Objects.requireNonNull(planId, "planId");
        Set<String> excluded = new HashSet<>();
        if (excludedNormalizedIdentifiers != null) {
            for (String value : excludedNormalizedIdentifiers) {
                String normalized = normalize(value);
                if (normalized != null) excluded.add(normalized);
            }
        }

        // A returned number is already reserved. If the same request explicitly
        // supplied it on another line, keep that reservation for the explicit line
        // and advance once more for this automatic line.
        for (int attempt = 0; attempt <= excluded.size(); attempt++) {
            String candidate = normalize(jdbc.queryForObject(
                    ALLOCATE_SQL, String.class, planId));
            if (candidate == null) {
                throw new IllegalStateException(
                        "Database returned a blank production product number");
            }
            if (!excluded.contains(candidate)) return candidate;
        }
        throw new IllegalStateException(
                "Unable to allocate a product number outside explicit request values");
    }

    static String normalize(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed.toUpperCase(Locale.ROOT);
    }

}
