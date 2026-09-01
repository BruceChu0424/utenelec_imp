package com.uten.imp.features.warehouse.history;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
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
            int page,
            int size) {
        PageRequest pageable = Pageables.of(page, size);
        int safePage = pageable.getPageNumber() + 1;
        int safeSize = pageable.getPageSize();
        String normalizedKeyword = normalize(keyword);

        Query countQuery = bindFilters(
                entityManager.createNativeQuery(
                        WarehouseHistoryQueries.countSql(type)),
                normalizedKeyword,
                status);
        long total = number(countQuery.getSingleResult()).longValue();
        if (total == 0) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }

        Query rowsQuery = bindFilters(
                entityManager.createNativeQuery(
                        WarehouseHistoryQueries.listSql(type)),
                normalizedKeyword,
                status)
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

    private Query bindFilters(Query query, String keyword, Short status) {
        return query.setParameter("keyword", keyword)
                .setParameter("keyword_pattern", "%" + keyword.toLowerCase() + "%")
                .setParameter("status", status);
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
        UUID makerId = uuid(row[10]);
        UUID approverId = uuid(row[11]);
        return new HeaderRow(
                uuid(row[0]),
                text(row[1]),
                localDate(row[2]),
                uuid(row[3]),
                text(row[4]),
                uuid(row[5]),
                text(row[6]),
                shortNumber(row[7]),
                bool(row[8]),
                text(row[9]),
                makerId,
                employeeName(makerId, text(row[12]), employeeCache),
                approverId,
                employeeName(approverId, text(row[13]), employeeCache),
                text(row[14]));
    }

    private WarehouseHistoryLine toLine(Object[] row) {
        return new WarehouseHistoryLine(
                uuid(row[0]),
                integer(row[1]),
                uuid(row[2]),
                text(row[3]),
                text(row[4]),
                text(row[5]),
                text(row[6]),
                text(row[7]),
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
                text(row[19]),
                text(row[20]),
                decimal(row[21]),
                decimal(row[22]),
                decimal(row[23]),
                text(row[24]),
                decimal(row[25]),
                text(row[26]),
                text(row[27]));
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

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID uuid ? uuid : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
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

    private static boolean bool(Object value) {
        return value instanceof Boolean bool ? bool : Boolean.parseBoolean(String.valueOf(value));
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
