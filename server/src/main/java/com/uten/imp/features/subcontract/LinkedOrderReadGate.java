package com.uten.imp.features.subcontract;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * 委外物流单据「经关联订货单只读放行」门（V304）。
 *
 * <p>仓库执行的进仓/成品退/材料退单 maker 是仓库账号，按 maker 归属对委外不可见；
 * 但委外是这些单据所执行订货单的归属人，须能在订货单进度区点击单号溯源详情。
 * 归属人不可读且关联订货也不可读时仍 404（不泄露存在性）；写操作不走本门
 * （仍由 maker 归属 + 权限点双重把关）。
 */
@Component
@RequiredArgsConstructor
public class LinkedOrderReadGate {

    private final EntityManager em;
    private final SubcontractDocumentAccessPolicy access;

    public void requireReadableViaOrder(UUID makerId, String notFoundMessage,
                                        LinkedDocKind kind, UUID docId) {
        if (access.canRead(makerId)) {
            return;
        }
        if (readableViaLinkedOrder(kind, docId)) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, notFoundMessage);
    }

    private boolean readableViaLinkedOrder(LinkedDocKind kind, UUID docId) {
        String sql = switch (kind) {
            case RECEIPT -> """
                    SELECT DISTINCT o.maker_id FROM subcontract_receipt_items ri
                    JOIN subcontract_order_items oi ON oi.id = ri.order_item_id
                    JOIN subcontract_orders o ON o.id = oi.order_id
                    WHERE ri.receipt_id = :id AND o.is_deleted = FALSE
                    """;
            case RETURN -> """
                    SELECT DISTINCT o.maker_id FROM subcontract_return_items ri
                    JOIN subcontract_order_items oi ON oi.id = ri.order_item_id
                    JOIN subcontract_orders o ON o.id = oi.order_id
                    WHERE ri.return_id = :id AND o.is_deleted = FALSE
                    """;
            case MATERIAL_RETURN -> """
                    SELECT DISTINCT o.maker_id FROM subcontract_material_return_items ri
                    LEFT JOIN subcontract_order_items oi
                      ON oi.id = COALESCE(ri.order_item_id, (
                          SELECT ii.order_item_id FROM subcontract_material_issue_items ii
                          WHERE ii.id = ri.material_issue_item_id))
                    JOIN subcontract_orders o ON o.id = oi.order_id
                    WHERE ri.material_return_id = :id AND o.is_deleted = FALSE
                    """;
        };
        List<?> makers = em.createNativeQuery(sql).setParameter("id", docId).getResultList();
        return makers.stream()
                .filter(java.util.Objects::nonNull)
                .map(m -> (UUID) m)
                .anyMatch(access::canRead);
    }

    public enum LinkedDocKind {
        RECEIPT,
        RETURN,
        MATERIAL_RETURN
    }
}
