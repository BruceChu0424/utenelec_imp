package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Source-linked receipt forms may omit readonly terms; approved source facts fill them. */
public final class ProcurementReceiptHeaderAuthority {
    private ProcurementReceiptHeaderAuthority() {}

    public record Header(UUID currencyId, BigDecimal taxRate, UUID settlementMethodId) {}

    /** Existing explicit inputs still pass the ordinary source validation at approval. */
    public static Header deriveIfMissing(EntityManager em, String kind, List<UUID> orderItemIds,
            UUID currencyId, BigDecimal taxRate, UUID settlementMethodId) {
        Header supplied = new Header(currencyId, taxRate, settlementMethodId);
        String prefix = switch (kind) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unknown procurement kind");
        };
        if (currencyId != null && taxRate != null && settlementMethodId != null) return supplied;
        List<UUID> ids = orderItemIds == null ? List.of()
                : orderItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) return supplied;
        @SuppressWarnings("unchecked") List<Object[]> sources = em.createNativeQuery(
                "SELECT i.id,h.currency_id,h.tax_rate,h.settlement_method_id FROM " + prefix + "_order_items i "
                + "JOIN " + prefix + "_orders h ON h.id=i.order_id WHERE i.id IN (:ids) "
                + "AND NOT i.is_deleted AND NOT h.is_deleted ORDER BY i.id")
                .setParameter("ids", ids).getResultList();
        if (sources.size() != ids.size()) throw conflict("收货来源订货单明细不存在或已删除");
        var seen = new HashSet<UUID>();
        Header authority = null;
        for (Object[] source : sources) {
            if (!seen.add((UUID) source[0]) || !ids.contains((UUID) source[0]))
                throw conflict("收货来源订货单明细重复或不一致");
            Header next = new Header((UUID) source[1], (BigDecimal) source[2], (UUID) source[3]);
            if (next.currencyId() == null || next.taxRate() == null || next.settlementMethodId() == null)
                throw conflict("收货来源商业条款不完整，请先核对来源订货单");
            if (authority != null && !same(authority, next))
                throw conflict("收货来源币种、税率或结算方式不同，请按商业条款分单");
            authority = next;
        }
        if ((currencyId != null && !currencyId.equals(authority.currencyId()))
                || (taxRate != null && taxRate.compareTo(authority.taxRate()) != 0)
                || (settlementMethodId != null && !settlementMethodId.equals(authority.settlementMethodId())))
            throw conflict("收货币种、税率或结算方式与来源订货单不一致");
        return authority;
    }

    private static boolean same(Header a, Header b) {
        return a.currencyId().equals(b.currencyId()) && a.taxRate().compareTo(b.taxRate()) == 0
                && a.settlementMethodId().equals(b.settlementMethodId());
    }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
