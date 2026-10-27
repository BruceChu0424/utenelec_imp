package com.uten.imp.common.export;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.util.*;

/** Shared joins and factual labels for the two supplier-facing order documents. */
public final class ProcurementOrderPrintSupport {
    public enum Domain {
        PURCHASE("purchase"), SUBCONTRACT("subcontract");
        private final String table;
        Domain(String table) { this.table = table; }
    }
    private ProcurementOrderPrintSupport() { }
    @com.fasterxml.jackson.annotation.JsonPropertyOrder({"header", "lines", "companyName", "reviewerName"})
    public static final class Facts {
        private final Object[] header;
        private final Map<UUID,Object[]> lines;
        private final String companyName;
        private final String reviewerName;

        @com.fasterxml.jackson.annotation.JsonCreator
        public Facts(@com.fasterxml.jackson.annotation.JsonProperty("header") Object[] header,
                @com.fasterxml.jackson.annotation.JsonProperty("lines") Map<UUID,Object[]> lines,
                @com.fasterxml.jackson.annotation.JsonProperty("companyName") String companyName,
                @com.fasterxml.jackson.annotation.JsonProperty("reviewerName") String reviewerName) {
            this.header = header == null ? null : header.clone();
            this.lines = copyRows(lines);
            this.companyName = companyName;
            this.reviewerName = reviewerName;
        }

        @com.fasterxml.jackson.annotation.JsonProperty("header")
        public Object[] header() {
            return header == null ? null : header.clone();
        }

        @com.fasterxml.jackson.annotation.JsonProperty("lines")
        public Map<UUID,Object[]> lines() {
            return copyRows(lines);
        }

        @com.fasterxml.jackson.annotation.JsonProperty("companyName")
        public String companyName() { return companyName; }

        @com.fasterxml.jackson.annotation.JsonProperty("reviewerName")
        public String reviewerName() { return reviewerName; }

        @Override public boolean equals(Object other) {
            return this == other || other instanceof Facts that
                    && Objects.equals(header, that.header) && Objects.equals(lines, that.lines)
                    && Objects.equals(companyName, that.companyName) && Objects.equals(reviewerName, that.reviewerName);
        }

        @Override public int hashCode() {
            int hash = Objects.hashCode(header);
            hash = 31 * hash + Objects.hashCode(lines);
            hash = 31 * hash + Objects.hashCode(companyName);
            return 31 * hash + Objects.hashCode(reviewerName);
        }

        @Override public String toString() {
            return "Facts[header=" + Arrays.toString(header) + ", lines=" + lines + ", companyName=" + companyName
                    + ", reviewerName=" + reviewerName + "]";
        }
    }

    private static Map<UUID,Object[]> copyRows(Map<UUID,Object[]> rows) {
        if (rows == null) return null;
        Map<UUID,Object[]> snapshot = new LinkedHashMap<>();
        rows.forEach((id, row) -> snapshot.put(id, row == null ? null : row.clone()));
        return Collections.unmodifiableMap(snapshot);
    }

    public static Facts read(EntityManager em, CompanyBrandingReadPort branding,
            EmployeeNameResolver names, Domain domain, UUID id, boolean financeApproved) {
        // Call only after the owning detail service has authorized this exact document.
        Object[] header = (Object[]) em.createNativeQuery("""
                SELECT s.name, s.linkman, s.phone, s.mobile,
                       c.name, c.code, sm.name, w.name, w.location,
                       (SELECT support_phone FROM platform_branding WHERE id = 1)
                FROM %s_orders o
                LEFT JOIN suppliers s ON s.id = o.supplier_id
                LEFT JOIN currencies c ON c.id = o.currency_id
                LEFT JOIN settlement_methods sm ON sm.id = o.settlement_method_id
                LEFT JOIN warehouses w ON w.id = o.warehouse_id
                WHERE o.id = :id
                """.formatted(domain.table)).setParameter("id", id).getSingleResult();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, g.code, g.name, g.model, g.spec, g.material, c.name, u.name
                FROM %s_order_items i
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :id AND NOT i.is_deleted
                ORDER BY i.line_no, i.id
                """.formatted(domain.table)).setParameter("id", id).getResultList();
        Map<UUID,Object[]> descriptions = new LinkedHashMap<>();
        rows.forEach(row -> descriptions.put((UUID) row[0], row));
        String reviewer = "";
        if (financeApproved) {
            @SuppressWarnings("unchecked")
            List<Object[]> cases = em.createNativeQuery("""
                    SELECT status, decided_by_employee_id FROM procurement_order_approval_cases
                    WHERE order_type = '%s' AND order_id = :id AND request_type='ORDER'
                    ORDER BY attempt DESC LIMIT 1
                    """.formatted(domain.name())).setParameter("id", id).getResultList();
            if (!cases.isEmpty() && "APPROVED".equals(cases.getFirst()[0]) && cases.getFirst()[1] != null)
                reviewer = text(names.nameOf((UUID) cases.getFirst()[1]));
        }
        return new Facts(header, descriptions, branding.currentIdentity().companyName(), reviewer);
    }

    public static Object[] line(Facts facts, UUID id) {
        // Read the owned snapshot directly so printing n lines does not copy
        // the entire row map n times; return only a copy of the selected row.
        Object[] row = facts.lines.get(id);
        if (row == null) throw new ApiException(ErrorCode.CONFLICT, "订货明细已变化，请刷新后重试打印");
        return row.clone();
    }
    public static boolean financeApproved(Short status, String finance) {
        return status != null && status == 1 && "APPROVED".equals(finance);
    }
    public static String status(Short status, String finance, String closureStatus, String closureMode) {
        if (status != null && status == 2) return "已取消";
        if (status != null && status == -1) return "已反审";
        if ("APPROVED".equals(closureStatus))
            return "DIRECT".equals(closureMode) ? "已结束(取消剩余)" : "已结束(历史财务批准)";
        return switch (finance == null ? "" : finance) {
            case "PENDING" -> status != null && status == 1 ? "改量待财务复核" : "等待财务审核";
            case "REJECTED" -> "财务退回";
            case "APPROVED" -> "财务已通过";
            default -> status != null && status == 1 ? "历史已审" : "草稿";
        };
    }
    public static String text(Object value) { return value == null ? "" : value.toString().trim(); }
    public static String decimal(java.math.BigDecimal value) { return value == null ? null : value.toPlainString(); }
    public static String first(String primary, String fallback) { return primary.isBlank() ? fallback : primary; }
    public static String join(String first, String second) { return second.isBlank() ? first : first + " " + second; }
}
