package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.finance.payables.ProcurementPayablesContracts.*;

/** Server-authoritative purchase/subcontract AP workbench. */
@Service
@RequiredArgsConstructor
public class ProcurementPayablesService {
    private static final int MAX_PAGE_SIZE = 200;
    private static final int MAX_PAYMENT_PREVIEW = 100;
    private static final Set<String> BUSINESS_TYPES = Set.of("PURCHASE", "SUBCONTRACT", "DIRECT");
    private static final Set<String> STATUSES = Set.of(
            "OPEN", "PARTIAL", "SETTLED", "OVERDUE", "CREDIT", "UNDATED");
    private static final Map<String, String> SORTS = Map.of(
            "billDate", "ledger.bill_date",
            "dueDate", "ledger.due_date",
            "supplierName", "supplier.name",
            "grossLocal", "ledger.amount_original_local",
            "outstandingLocal", "ledger.amount_balance");

    private final EntityManager em;
    private final SupplierPayableHoldGuard payableHoldGuard;

    @Transactional(readOnly = true)
    public Page list(
            String businessType,
            UUID supplierId,
            String status,
            UUID settlementMethodId,
            LocalDate dateFrom,
            LocalDate dateTo,
            LocalDate dueFrom,
            LocalDate dueTo,
            String keyword,
            int page,
            int size,
            String sort,
            String order) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), MAX_PAGE_SIZE);
        Filter filter = filter(businessType, supplierId, status, settlementMethodId,
                dateFrom, dateTo, dueFrom, dueTo, keyword);
        String orderBy = orderBy(sort, order);

        Query data = em.createNativeQuery(itemSelect() + filter.sql()
                + " ORDER BY " + orderBy + " LIMIT :limit OFFSET :offset");
        bind(data, filter.params());
        data.setParameter("limit", safeSize);
        data.setParameter("offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = data.getResultList();

        Query count = em.createNativeQuery("SELECT COUNT(*) " + baseFrom() + filter.sql());
        bind(count, filter.params());
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);

        return new Page(summary(filter), items(rows),
                safePage, safeSize, total, totalPages);
    }

    @Transactional(readOnly = true)
    public Detail detail(UUID id) {
        Item item = requireItem(id);
        @SuppressWarnings("unchecked")
        List<Object[]> paymentRows = em.createNativeQuery("""
                SELECT payment.id, payment.bill_no, payment.bill_date,
                       line.amount_original, line.amount_local,
                       COALESCE(line.applied_amount_local,
                                line.amount_local - COALESCE(line.exchange_diff, 0)),
                       COALESCE(line.exchange_diff, 0), payment.status
                FROM finance_payment_lines line
                JOIN finance_payments payment ON payment.id = line.payment_id
                WHERE line.applied_ledger_id = :id
                  AND COALESCE(line.is_deleted, FALSE) = FALSE
                  AND COALESCE(payment.is_deleted, FALSE) = FALSE
                ORDER BY payment.bill_date, payment.bill_no, line.id
                """).setParameter("id", id).getResultList();
        List<PaymentAllocation> payments = paymentRows.stream()
                .map(row -> new PaymentAllocation(
                        uuid(row[0]), text(row[1]), date(row[2]), money(row[3]), money(row[4]),
                        money(row[5]), money(row[6]), ((Number) row[7]).shortValue()))
                .toList();

        @SuppressWarnings("unchecked")
        List<Object[]> offsetRows = em.createNativeQuery("""
                SELECT allocation.id, allocation.source_ledger_id, source.bill_no,
                       allocation.amount_original, allocation.source_amount_local,
                       allocation.target_amount_local, allocation.effective_date,
                       allocation.status, allocation.reason
                FROM supplier_open_item_offsets allocation
                JOIN ar_ap_ledger source ON source.id = allocation.source_ledger_id
                WHERE allocation.target_ledger_id = :id
                ORDER BY allocation.effective_date, allocation.id
                """).setParameter("id", id).getResultList();
        List<OffsetAllocation> offsets = offsetRows.stream()
                .map(row -> new OffsetAllocation(
                        uuid(row[0]), uuid(row[1]), text(row[2]), money(row[3]), money(row[4]),
                        money(row[5]), date(row[6]), text(row[7]), text(row[8])))
                .toList();
        return new Detail(item, payments, offsets);
    }

    @Transactional(readOnly = true)
    public PaymentPreview paymentPreview(PaymentPreviewRequest request) {
        List<UUID> ids = request == null || request.payableIds() == null
                ? List.of()
                : request.payableIds().stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty() || ids.size() > MAX_PAYMENT_PREVIEW) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "请选择 1 至 " + MAX_PAYMENT_PREVIEW + " 笔应付生成付款预览");
        }
        Query query = em.createNativeQuery(itemSelect()
                + " WHERE ledger.id IN (:ids) AND ledger.direction = 'AP'"
                + " AND ledger.status = 1 AND COALESCE(ledger.is_deleted, FALSE) = FALSE"
                + " ORDER BY ledger.id");
        query.setParameter("ids", ids);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.size() != ids.size()) {
            return new PaymentPreview(false, "部分应付已不存在、已红冲或无权引用",
                    null, null, null, null, "0.0000", "0.0000", List.of());
        }
        List<Item> items = items(rows);
        UUID supplierId = items.getFirst().supplierId();
        UUID currencyId = items.getFirst().currencyId();
        if (items.stream().anyMatch(value -> !Objects.equals(supplierId, value.supplierId()))) {
            return previewFailure("所选应付必须属于同一供应商", items);
        }
        if (items.stream().anyMatch(value -> !Objects.equals(currencyId, value.currencyId()))) {
            return previewFailure("跨币种核销需要独立双币模型；本次只能选择同一币种", items);
        }
        if (items.stream().anyMatch(value -> !"PAYABLE".equals(value.openItemKind())
                || decimal(value.outstandingOriginal()).signum() <= 0)) {
            return previewFailure("付款只能引用仍有正数未付余额的应付项目", items);
        }
        if (items.stream().anyMatch(Item::paymentHeld)) {
            String reason = items.stream().filter(Item::paymentHeld)
                    .map(Item::holdReason).filter(Objects::nonNull)
                    .findFirst().orElse("IQC待检或不合格退回/贷项尚未闭环");
            return previewFailure(reason, items);
        }
        BigDecimal original = items.stream().map(Item::outstandingOriginal)
                .map(ProcurementPayablesService::decimal).reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal local = items.stream().map(Item::outstandingLocal)
                .map(ProcurementPayablesService::decimal).reduce(BigDecimal.ZERO, BigDecimal::add);
        Item first = items.getFirst();
        return new PaymentPreview(true, null, supplierId, first.supplierName(), currencyId,
                first.currencyCode(), money(original), money(local), items);
    }

    private PaymentPreview previewFailure(String reason, List<Item> items) {
        Item first = items.isEmpty() ? null : items.getFirst();
        return new PaymentPreview(false, reason,
                first == null ? null : first.supplierId(),
                first == null ? null : first.supplierName(),
                first == null ? null : first.currencyId(),
                first == null ? null : first.currencyCode(),
                "0.0000", "0.0000", items);
    }

    private Item requireItem(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(itemSelect()
                        + " WHERE ledger.id = :id AND ledger.direction = 'AP'"
                        + " AND ledger.status = 1 AND COALESCE(ledger.is_deleted, FALSE) = FALSE")
                .setParameter("id", id)
                .setMaxResults(2)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "应付项目不存在或已失效");
        }
        return items(rows).getFirst();
    }

    private Summary summary(Filter filter) {
        Query query = em.createNativeQuery("""
                SELECT
                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'
                        THEN GREATEST(ledger.amount_original_local, 0) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'
                        THEN GREATEST(ledger.amount_received_local, 0) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'
                        THEN GREATEST(ledger.amount_settled, 0) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'
                        THEN ledger.amount_received_local-ledger.amount_settled
                        ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'
                        THEN GREATEST(ledger.amount_offset_local, 0) ELSE 0 END), 0),
                    COALESCE(SUM(GREATEST(ledger.amount_balance, 0)), 0),
                    COALESCE(SUM(CASE WHEN ledger.amount_balance > 0
                        AND ledger.due_date < CURRENT_DATE THEN ledger.amount_balance ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN ledger.amount_balance > 0
                        AND date_trunc('month', ledger.due_date) = date_trunc('month', CURRENT_DATE)
                        THEN ledger.amount_balance ELSE 0 END), 0),
                    ABS(COALESCE(SUM(CASE WHEN ledger.open_item_kind IN ('CREDIT', 'CLAIM_CREDIT')
                        AND ledger.amount_balance < 0 THEN ledger.amount_balance ELSE 0 END), 0)),
                    ABS(COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PREPAYMENT'
                        AND ledger.amount_balance < 0 THEN ledger.amount_balance ELSE 0 END), 0))
                """ + baseFrom() + filter.sql());
        bind(query, filter.params());
        Object[] row = (Object[]) query.getSingleResult();

        String lossSql = """
                SELECT COUNT(*) FROM subcontract_loss_cases loss
                WHERE COALESCE(loss.is_deleted, FALSE) = FALSE
                  AND loss.status IN ('OPEN', 'ACCEPTED', 'DISPUTED', 'AWAITING_FULFILLMENT')
                """ + (filter.params().containsKey("supplierId")
                ? " AND loss.supplier_id = :supplierId" : "");
        Query lossCount = em.createNativeQuery(lossSql);
        if (filter.params().containsKey("supplierId")) {
            lossCount.setParameter("supplierId", filter.params().get("supplierId"));
        }
        long pendingLoss = ((Number) lossCount.getSingleResult()).longValue();
        return new Summary(money(row[0]),money(row[1]),money(row[2]),money(row[3]),
                money(row[4]),money(row[5]),money(row[6]),money(row[7]),money(row[8]),
                money(row[9]),pendingLoss);
    }

    private Filter filter(
            String businessType, UUID supplierId, String status, UUID settlementMethodId,
            LocalDate dateFrom, LocalDate dateTo, LocalDate dueFrom, LocalDate dueTo,
            String keyword) {
        String normalizedBusiness = upper(businessType);
        String normalizedStatus = upper(status);
        if (normalizedBusiness != null && !BUSINESS_TYPES.contains(normalizedBusiness)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "业务类型仅支持 PURCHASE/SUBCONTRACT/DIRECT");
        }
        if (normalizedStatus != null && !STATUSES.contains(normalizedStatus)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "应付状态仅支持 OPEN/PARTIAL/SETTLED/OVERDUE/CREDIT/UNDATED");
        }
        if (dateFrom != null && dateTo != null && dateFrom.isAfter(dateTo)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "立账起始日期不能晚于结束日期");
        }
        if (dueFrom != null && dueTo != null && dueFrom.isAfter(dueTo)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "到期起始日期不能晚于结束日期");
        }
        StringBuilder sql = new StringBuilder(" WHERE ledger.direction = 'AP'"
                + " AND ledger.status = 1 AND COALESCE(ledger.is_deleted, FALSE) = FALSE");
        Map<String, Object> params = new LinkedHashMap<>();
        if (normalizedBusiness != null) add(sql, params, "ledger.business_type = :businessType",
                "businessType", normalizedBusiness);
        if (supplierId != null) add(sql, params, "ledger.supplier_id = :supplierId", "supplierId", supplierId);
        if (settlementMethodId != null) add(sql, params,
                "ledger.settlement_type_id = :settlementMethodId", "settlementMethodId", settlementMethodId);
        if (dateFrom != null) add(sql, params, "ledger.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) add(sql, params, "ledger.bill_date <= :dateTo", "dateTo", dateTo);
        if (dueFrom != null) add(sql, params, "ledger.due_date >= :dueFrom", "dueFrom", dueFrom);
        if (dueTo != null) add(sql, params, "ledger.due_date <= :dueTo", "dueTo", dueTo);
        if (keyword != null && !keyword.isBlank()) {
            add(sql, params, "(LOWER(COALESCE(ledger.bill_no,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(ledger.source_doc_no,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(supplier.code,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword)",
                    "keyword", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        if (normalizedStatus != null) {
            sql.append(" AND ").append(switch (normalizedStatus) {
                case "OPEN" -> "ledger.amount_balance > 0";
                case "PARTIAL" -> "ledger.amount_balance > 0 AND "
                        + "(ledger.amount_received_local > 0 OR ledger.amount_offset_local > 0)";
                case "SETTLED" -> "ledger.amount_balance = 0";
                case "OVERDUE" -> "ledger.amount_balance > 0 AND ledger.due_date < CURRENT_DATE";
                case "CREDIT" -> "ledger.amount_balance < 0";
                case "UNDATED" -> "ledger.amount_balance > 0 AND ledger.due_date IS NULL";
                default -> throw new IllegalStateException("unreachable status " + normalizedStatus);
            });
        }
        return new Filter(sql.toString(), params);
    }

    private static void add(StringBuilder sql, Map<String, Object> params,
                            String predicate, String name, Object value) {
        sql.append(" AND ").append(predicate);
        params.put(name, value);
    }

    private static void bind(Query query, Map<String, Object> params) {
        params.forEach(query::setParameter);
    }

    private static String orderBy(String sort, String order) {
        // Map.of 不接受 null 键：未传排序参数时必须先短路到默认列
        String column = sort == null ? null : SORTS.get(sort);
        if (column == null) column = "ledger.due_date";
        String direction = "asc".equalsIgnoreCase(order) ? "ASC" : "DESC";
        return column + " " + direction + " NULLS LAST, ledger.bill_date DESC, ledger.id";
    }

    private static String itemSelect() {
        return """
                SELECT ledger.id, ledger.business_type, ledger.open_item_kind,
                       ledger.source_doc_type, ledger.source_doc_id, ledger.source_doc_no,
                       supplier.id, supplier.code, supplier.name,
                       ledger.bill_date, ledger.due_date,
                       to_char(date_trunc('month', ledger.bill_date), 'YYYY-MM'),
                       method.id, method.code, method.name,
                       COALESCE(NULLIF(supplier.tday, 0), method.default_due_days),
                       currency.id, currency.code, currency.name, ledger.exchange_rate,
                       ledger.amount_original, ledger.amount_original_local,
                       ledger.amount_received_original, ledger.amount_received_local,
                       ledger.amount_offset_original, ledger.amount_offset_local,
                       ledger.amount_balance_original, ledger.amount_balance,
                       CASE
                           WHEN ledger.amount_balance < 0
                                AND ledger.open_item_kind = 'PAYABLE' THEN 'CREDIT'
                           WHEN ledger.amount_balance < 0 THEN ledger.open_item_kind
                           WHEN ledger.amount_balance = 0 THEN 'SETTLED'
                           WHEN ledger.due_date < CURRENT_DATE THEN 'OVERDUE'
                           WHEN ledger.amount_received_local > 0 OR ledger.amount_offset_local > 0 THEN 'PARTIAL'
                           WHEN ledger.due_date IS NULL THEN 'UNDATED'
                           ELSE 'OPEN'
                       END,
                       CASE WHEN ledger.amount_balance > 0 AND ledger.due_date < CURRENT_DATE
                           THEN CURRENT_DATE - ledger.due_date ELSE 0 END,
                       ledger.remark
                """ + baseFrom();
    }

    private static String baseFrom() {
        return """
                 FROM ar_ap_ledger ledger
                 JOIN suppliers supplier ON supplier.id = ledger.supplier_id
                 LEFT JOIN currencies currency ON currency.id = ledger.currency_id
                 LEFT JOIN settlement_methods method ON method.id = ledger.settlement_type_id
                """;
    }

    private List<Item> items(List<Object[]> rows) {
        List<UUID> ids = rows.stream().map(row -> uuid(row[0])).toList();
        Map<UUID, SupplierPayableHoldGuard.HoldInfo> holds =
                payableHoldGuard.holdInfos(ids);
        return rows.stream().map(row -> item(row, holds)).toList();
    }

    private Item item(
            Object[] row,
            Map<UUID, SupplierPayableHoldGuard.HoldInfo> holds) {
        UUID ledgerId = uuid(row[0]);
        SupplierPayableHoldGuard.HoldInfo hold = holds.getOrDefault(
                ledgerId,
                new SupplierPayableHoldGuard.HoldInfo(false, null, BigDecimal.ZERO));
        return new Item(
                ledgerId, text(row[1]), text(row[2]), text(row[3]), uuid(row[4]), text(row[5]),
                uuid(row[6]), text(row[7]), text(row[8]), date(row[9]), date(row[10]), text(row[11]),
                uuid(row[12]), text(row[13]), text(row[14]), integer(row[15]), uuid(row[16]), text(row[17]),
                text(row[18]), rate(row[19]), money(row[20]), money(row[21]), money(row[22]),
                money(row[23]), money(row[24]), money(row[25]), money(row[26]), money(row[27]),
                text(row[28]), integer(row[29]) == null ? 0 : integer(row[29]), text(row[30]),
                hold.held(), hold.reason(), money(hold.failedBaseQty()));
    }

    private static String upper(String value) {
        return value == null || value.isBlank() ? null : value.trim().toUpperCase(Locale.ROOT);
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID uuid ? uuid : value == null ? null : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static String date(Object value) {
        return value == null ? null : value.toString();
    }

    private static Integer integer(Object value) {
        return value instanceof Number number ? number.intValue() : value == null ? null : Integer.valueOf(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        if (value instanceof Number number) return new BigDecimal(number.toString());
        return new BigDecimal(value.toString());
    }

    private static String money(Object value) {
        return value == null ? null : decimal(value).setScale(4, RoundingMode.HALF_UP).toPlainString();
    }

    private static String rate(Object value) {
        return value == null ? null : decimal(value).setScale(6, RoundingMode.HALF_UP).toPlainString();
    }

    private record Filter(String sql, Map<String, Object> params) {}
}
