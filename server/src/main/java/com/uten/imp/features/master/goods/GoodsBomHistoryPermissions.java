package com.uten.imp.features.master.goods;

import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Set;

/** Records command permissions, rather than inferring them from a move's delete/insert storage shape. */
@Component
@RequiredArgsConstructor
public class GoodsBomHistoryPermissions {
    private final NamedParameterJdbcTemplate db;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(propagation = Propagation.MANDATORY)
    public void record(Set<String> permissions) {
        db.update("""
                UPDATE goods_operation_history
                SET required_permissions=CAST(string_to_array(:permissions,',') AS text[])
                WHERE actor_id=:actor AND transaction_id=txid_current() AND operation_type='BOM_EDIT'
                """, Map.of("actor", currentUser.requireId(),
                "permissions", String.join(",", permissions.stream().sorted().toList())));
    }
}
