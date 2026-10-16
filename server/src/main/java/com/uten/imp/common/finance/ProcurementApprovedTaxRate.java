package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.JdbcTemplate;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Submitted tax remains immutable; finance confirms the effective tax at approval. */
public final class ProcurementApprovedTaxRate {
    private ProcurementApprovedTaxRate() {}

    public static BigDecimal normalize(BigDecimal tax) {
        if (tax != null && (tax.signum() < 0 || tax.compareTo(new BigDecimal("100")) > 0
                || tax.stripTrailingZeros().scale() > 4))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "财务税率须为0至100，最多4位小数");
        return tax;
    }
    public static BigDecimal read(JdbcTemplate jdbc, String kind, UUID order, BigDecimal fallback) {
        List<BigDecimal> rows = jdbc.query("""
                SELECT finance_tax_rate FROM procurement_order_approval_cases
                WHERE order_type=? AND order_id=? AND status='APPROVED'
                ORDER BY attempt DESC LIMIT 1
                """, (rs,n) -> rs.getBigDecimal(1), kind, order);
        return normalize(rows.isEmpty() || rows.getFirst() == null ? fallback : rows.getFirst());
    }
    public static BigDecimal read(EntityManager em, String kind, UUID order, BigDecimal fallback) {
        @SuppressWarnings("unchecked") List<BigDecimal> rows = em.createNativeQuery("""
                SELECT finance_tax_rate FROM procurement_order_approval_cases
                WHERE order_type=:kind AND order_id=:order AND status='APPROVED'
                ORDER BY attempt DESC LIMIT 1
                """).setParameter("kind",kind).setParameter("order",order).getResultList();
        return normalize(rows.isEmpty() || rows.getFirst() == null ? fallback : rows.getFirst());
    }
    public static void requireReviewedTax(JdbcTemplate jdbc, String kind, UUID order, BigDecimal tax) {
        normalize(tax);
        if (tax == null) throw new ApiException(ErrorCode.CONFLICT, "来源订货税率缺失，请先核对提交事实");
        String prefix = switch (kind) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unknown procurement kind");
        };
        Long count = jdbc.queryForObject("SELECT COUNT(*) FROM "+prefix+"_receipt_items i JOIN "+prefix
                +"_receipts r ON r.id=i.receipt_id JOIN "+prefix+"_order_items source ON source.id=i.order_item_id "
                +"WHERE source.order_id=? AND r.status=1 AND NOT r.is_deleted AND NOT i.is_deleted "
                +"AND (r.tax_rate IS NULL OR r.tax_rate<>?)",Long.class,order,tax);
        if (count != null && count > 0) throw new ApiException(ErrorCode.CONFLICT,
                "该订货单已有收货过账，财务税率须保持原过账税率；请先按原单办理退回或冲销");
    }
}
