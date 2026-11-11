package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.util.*;

/** Receipt ancestry is a locked server fact, including for drafts saved before this resolver existed. */
public final class ProcurementReturnOrderAuthority {
    private ProcurementReturnOrderAuthority() { }
    public record Source(UUID receiptItemId, UUID suppliedOrderItemId) { }

    public static Map<UUID, UUID> resolve(EntityManager em, String family, List<Source> sources) {
        String prefix = switch (family) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unsupported return family");
        };
        if (sources == null || sources.isEmpty()
                || sources.stream().anyMatch(source -> source == null || source.receiptItemId() == null))
            throw invalid("退货每一行必须唯一关联来源收货明细");
        List<UUID> ids = sources.stream().map(Source::receiptItemId).distinct().sorted().toList();
        if (ids.size() != sources.size()) throw invalid("退货每一行必须唯一关联来源收货明细");
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.id,item.order_item_id
                FROM %1$s_receipt_items item JOIN %1$s_receipts receipt ON receipt.id=item.receipt_id
                WHERE item.id IN (:ids) AND receipt.status=1
                  AND NOT item.is_deleted AND NOT receipt.is_deleted
                ORDER BY item.id FOR UPDATE OF item,receipt
                """.formatted(prefix)).setParameter("ids",ids).getResultList();
        if (rows.size()!=ids.size()) throw invalid("部分退货来源收货明细不存在、未审核或已失效");
        Map<UUID,UUID> authoritative = new HashMap<>();
        for (Object[] row : rows) authoritative.put((UUID)row[0],(UUID)row[1]);
        for (Source source : sources) {
            if (source.suppliedOrderItemId()!=null
                    && !Objects.equals(source.suppliedOrderItemId(),authoritative.get(source.receiptItemId())))
                throw invalid("退货提交的订货来源与来源收货明细不一致，请重新引入来源");
        }
        // A receipt with no order retains its established contract: null is a real source fact.
        return Collections.unmodifiableMap(authoritative);
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
