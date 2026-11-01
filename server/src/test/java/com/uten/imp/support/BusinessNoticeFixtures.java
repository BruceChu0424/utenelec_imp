package com.uten.imp.support;

import org.springframework.jdbc.core.JdbcTemplate;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

/** Explicit test subscriptions for an existing actor; never replaces its business identity. */
public final class BusinessNoticeFixtures {
    private BusinessNoticeFixtures() { }

    public static void grant(JdbcTemplate jdbc, UUID userId, String... codes) {
        var permissions = new LinkedHashSet<>(List.of(codes));
        assertFalse(permissions.isEmpty());
        assertEquals(codes.length, permissions.size(), "Fixture subscription codes must be unique");
        int changed = jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,'grant' FROM permissions WHERE code=ANY(CAST(? AS text[]))
                ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant',active=TRUE
                """, userId, "{" + String.join(",", permissions) + "}");
        assertEquals(permissions.size(), changed, "Every explicit subscription must use a real catalog permission");
    }
}
