package com.uten.imp.features.finance.arap;

import com.uten.imp.application.port.ClientCreditFactsPort;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.PartyOpenBalancePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.ClientCreditReadAccess;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Formal AR only. Receipts, offsets, prepayments and legacy-unverified amounts are never conflated. */
@Component
@RequiredArgsConstructor
public class AiClientCreditFactsQuery implements ClientCreditFactsPort {
    private final JdbcTemplate jdbc;
    private final PartyOpenBalancePort balances;
    private final MasterIntakeLookupPort clients;
    private final SecurityContextCurrentUser current;

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Snapshot read(UUID clientId) {
        CurrentAuthorityGuard.requireAll("client:view");
        if (!current.get().filter(ClientCreditReadAccess::canRead).isPresent()) throw new ApiException(ErrorCode.FORBIDDEN);
        if (clientId == null || clients.clientProfile(clientId) == null) throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        LocalDate today = BusinessTime.today();
        var open = balances.clients(List.of(clientId));
        return jdbc.queryForObject("""
                SELECT count(*) formal_rows,
                       count(*) FILTER (WHERE NOT is_settled AND amount_balance>0) open_rows,
                       count(*) FILTER (WHERE NOT is_settled AND amount_balance>0 AND due_date<?) overdue_rows,
                       COALESCE(sum(amount_balance) FILTER (WHERE NOT is_settled AND amount_balance>0 AND due_date<?),0) overdue_local,
                       count(*) FILTER (WHERE NOT is_settled AND amount_balance>0 AND due_date IS NULL) missing_due,
                       COALESCE(sum(amount_received_local),0) received_local,
                       max(settled_date) FILTER (WHERE is_settled) latest_settled
                FROM ar_ap_ledger
                WHERE client_id=? AND direction='AR' AND open_item_kind='RECEIVABLE'
                  AND status=1 AND is_deleted=FALSE
                """, (rs, row) -> new Snapshot(today, open, rs.getLong("formal_rows"), rs.getLong("open_rows"),
                rs.getLong("overdue_rows"), rs.getBigDecimal("overdue_local"), rs.getLong("missing_due"),
                rs.getBigDecimal("received_local"), rs.getObject("latest_settled", LocalDate.class)), today, today, clientId);
    }
}
