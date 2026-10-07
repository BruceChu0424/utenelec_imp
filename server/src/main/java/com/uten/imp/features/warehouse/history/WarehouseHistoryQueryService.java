package com.uten.imp.features.warehouse.history;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.NativeFacets;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Reads warehouse-only document history projections from fixed source tables. */
@Service
public class WarehouseHistoryQueryService {

    private final EntityManager entityManager;
    private final EmployeeNameResolver employeeNames;

    public WarehouseHistoryQueryService(
            EntityManager entityManager,
            EmployeeNameResolver employeeNames) {
        this.entityManager = entityManager;
        this.employeeNames = employeeNames;
    }

    @Transactional(readOnly = true)
    public PageResponse<WarehouseHistoryListItem> list(
            WarehouseHistoryType type,
            String keyword,
            Short status,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size) {
        return list(type, keyword, status, dateFrom, dateTo, page, size, null, null, null, null);
    }

    /** 同上；2026-09-25 单号列统一：sort/order 表头排序（白名单，未知回落默认
     *  单据日期倒序）、billNo/sourceDocNo 单据号/来源单据号表头值筛选（等值精确匹配，
     *  空参数即不过滤——WHERE 常驻 CAST 判空，参数恒绑定）。 */
    @Transactional(readOnly = true)
    public PageResponse<WarehouseHistoryListItem> list(
            WarehouseHistoryType type,
            String keyword,
            Short status,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size,
            String sort,
            String order,
            String billNo,
            String sourceDocNo) {
        PageRequest pageable = Pageables.of(page, size);
        int safePage = pageable.getPageNumber() + 1;
        int safeSize = pageable.getPageSize();
        String normalizedKeyword = normalize(keyword);
        String normalizedBillNo = normalizeToNull(billNo);
        String normalizedSourceDocNo = normalizeToNull(sourceDocNo);

        Query countQuery = bindFilters(
                entityManager.createNativeQuery(
                        WarehouseHistoryQueries.countSql(type)),
                normalizedKeyword,
                status,
                dateFrom,
                dateTo,
                normalizedBillNo,
                normalizedSourceDocNo);
        long total = number(countQuery.getSingleResult()).longValue();
        if (total == 0) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }

        Query rowsQuery = bindFilters(
                entityManager.createNativeQuery(
                        WarehouseHistoryQueries.listSql(
                                type, WarehouseHistoryQueries.orderBy(sort, order))),
                normalizedKeyword,
                status,
                dateFrom,
                dateTo,
                normalizedBillNo,
                normalizedSourceDocNo)
                .setParameter("limit", safeSize)
                .setParameter("offset", pageable.getOffset());
        Map<UUID, String> employeeCache = new HashMap<>();
        List<WarehouseHistoryListItem> items = NativeQueryResults.objectArrayRows(rowsQuery)
                .stream()
                .map(row -> toListItem(type, row, employeeCache))
                .toList();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo:[各单据号], sourceDocNo:[各来源
     *  单据号]}——与列表同一过滤基座（不含单号列自身值筛选），按单号分组计数、单号
     *  升序，上限 500 桶。 */
    @Transactional(readOnly = true)
    public Map<String, List<Map<String, Object>>> facets(
            WarehouseHistoryType type,
            String keyword,
            Short status,
            LocalDate dateFrom,
            LocalDate dateTo) {
        String normalizedKeyword = normalize(keyword);
        return Map.of(
                "billNo", billBuckets(type, "COALESCE(h.bill_no, '')",
                        normalizedKeyword, status, dateFrom, dateTo),
                "sourceDocNo", billBuckets(type, "COALESCE(h.source_doc_no, '')",
                        normalizedKeyword, status, dateFrom, dateTo));
    }

    private List<Map<String, Object>> billBuckets(
            WarehouseHistoryType type, String expr, String keyword, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        return NativeFacets.rowsOf(bindFilters(
                entityManager.createNativeQuery(
                        WarehouseHistoryQueries.facetsSql(type, expr)),
                keyword, status, dateFrom, dateTo, null, null)
                .setMaxResults(500));
    }

    @Transactional(readOnly = true)
    public WarehouseHistoryDetail detail(WarehouseHistoryType type, UUID id) {
        List<Object[]> headers = NativeQueryResults.objectArrayRows(
                entityManager.createNativeQuery(
                                WarehouseHistoryQueries.detailHeaderSql(type))
                        .setParameter("id", id)
                        .setMaxResults(1));
        if (headers.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "仓库历史单据不存在");
        }
        List<WarehouseHistoryLine> lines = NativeQueryResults.objectArrayRows(
                        entityManager.createNativeQuery(WarehouseHistoryQueries.detailLinesSql(type))
                                .setParameter("id", id))
                .stream()
                .map(this::toLine)
                .toList();
        Map<UUID, String> employeeCache = new HashMap<>();
        HeaderRow header = header(headers.getFirst(), employeeCache);
        return new WarehouseHistoryDetail(
                header.id(),
                type.pathSegment(),
                header.billNo(),
                header.billDate(),
                header.supplierId(),
                header.supplierName(),
                header.warehouseId(),
                header.warehouseName(),
                header.status(),
                header.closed(),
                header.sourceDocumentNo(),
                header.makerId(),
                header.makerName(),
                header.approverId(),
                header.approverName(),
                header.remark(),
                lines);
    }

    private Query bindFilters(
            Query query, String keyword, Short status, LocalDate dateFrom, LocalDate dateTo,
            String billNo, String sourceDocNo) {
        return query.setParameter("keyword", keyword)
                .setParameter("keyword_pattern", "%" + keyword.toLowerCase() + "%")
                .setParameter("status", status)
                .setParameter("date_from", dateFrom)
                .setParameter("date_to", dateTo)
                .setParameter("bill_no", billNo)
                .setParameter("source_doc_no", sourceDocNo);
    }

    private WarehouseHistoryListItem toListItem(
            WarehouseHistoryType type,
            Object[] row,
            Map<UUID, String> employeeCache) {
        HeaderRow header = header(row, employeeCache);
        return new WarehouseHistoryListItem(
                header.id(),
                type.pathSegment(),
                header.billNo(),
                header.billDate(),
                header.supplierId(),
                header.supplierName(),
                header.warehouseId(),
                header.warehouseName(),
                header.status(),
                header.closed(),
                header.sourceDocumentNo(),
                header.makerId(),
                header.makerName(),
                header.approverId(),
                header.approverName(),
                number(row[15]).longValue());
    }

    private HeaderRow header(Object[] row, Map<UUID, String> employeeCache) {
        UUID makerId = NativeValueConverters.uuid(row[10]);
        UUID approverId = NativeValueConverters.uuid(row[11]);
        return new HeaderRow(
                NativeValueConverters.uuid(row[0]),
                NativeValueConverters.text(row[1]),
                NativeValueConverters.toLocalDate(row[2]),
                NativeValueConverters.uuid(row[3]),
                NativeValueConverters.text(row[4]),
                NativeValueConverters.uuid(row[5]),
                NativeValueConverters.text(row[6]),
                shortNumber(row[7]),
                NativeValueConverters.booleanValue(row[8]),
                NativeValueConverters.text(row[9]),
                makerId,
                employeeName(makerId, NativeValueConverters.text(row[12]), employeeCache),
                approverId,
                employeeName(approverId, NativeValueConverters.text(row[13]), employeeCache),
                NativeValueConverters.text(row[14]));
    }

    private WarehouseHistoryLine toLine(Object[] row) {
        return new WarehouseHistoryLine(
                NativeValueConverters.uuid(row[0]),
                integer(row[1]),
                NativeValueConverters.uuid(row[2]),
                NativeValueConverters.text(row[3]),
                NativeValueConverters.text(row[4]),
                NativeValueConverters.text(row[5]),
                NativeValueConverters.text(row[6]),
                NativeValueConverters.text(row[7]),
                decimal(row[8]),
                decimal(row[9]),
                decimal(row[10]),
                decimal(row[11]),
                decimal(row[12]),
                decimal(row[13]),
                decimal(row[14]),
                decimal(row[15]),
                decimal(row[16]),
                decimal(row[17]),
                decimal(row[18]),
                NativeValueConverters.text(row[19]),
                NativeValueConverters.text(row[20]),
                decimal(row[21]),
                decimal(row[22]),
                decimal(row[23]),
                NativeValueConverters.text(row[24]),
                decimal(row[25]),
                NativeValueConverters.text(row[26]),
                NativeValueConverters.text(row[27]),
                NativeValueConverters.text(row[28]));
    }

    private String employeeName(
            UUID id,
            String legacyName,
            Map<UUID, String> employeeCache) {
        if (id == null) return normalizeToNull(legacyName);
        String cached = employeeCache.get(id);
        if (cached != null) return cached;
        String resolved = normalizeToNull(employeeNames.nameOf(id));
        String value = resolved == null ? normalizeToNull(legacyName) : resolved;
        if (value != null) employeeCache.put(id, value);
        return value;
    }

    private static String normalize(String value) {
        String normalized = normalizeToNull(value);
        return normalized == null ? "" : normalized;
    }

    private static String normalizeToNull(String value) {
        if (value == null) return null;
        String normalized = value.trim();
        return normalized.isEmpty() ? null : normalized;
    }

    private static Number number(Object value) {
        return value instanceof Number number ? number : new BigDecimal(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return null;
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static Short shortNumber(Object value) {
        return value == null ? null : number(value).shortValue();
    }

    private static Integer integer(Object value) {
        return value == null ? null : number(value).intValue();
    }

    private record HeaderRow(
            UUID id,
            String billNo,
            LocalDate billDate,
            UUID supplierId,
            String supplierName,
            UUID warehouseId,
            String warehouseName,
            Short status,
            boolean closed,
            String sourceDocumentNo,
            UUID makerId,
            String makerName,
            UUID approverId,
            String approverName,
            String remark) {
    }
}
