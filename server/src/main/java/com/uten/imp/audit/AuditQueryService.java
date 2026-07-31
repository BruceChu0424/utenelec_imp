package com.uten.imp.audit;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 审计日志查询（管理端读侧）。
 * <p>写侧由 {@link AuditService} / DB 触发器负责；本类只读，给 /api/admin/audit-logs 用。
 * <ul>
 *   <li>action：前缀模糊（如 "export" 匹配 export_purchase_report / export_sales_report ...）。</li>
 *   <li>actorAccount：子串模糊（不区分大小写）。</li>
 *   <li>dateFrom / dateTo：闭区间，按 created_at 过滤；业务日期边界使用 Asia/Shanghai，
 *       数据库存储仍为 TIMESTAMPTZ。</li>
 * </ul>
 * 默认按 created_at DESC（最新在前），单页最多 100 条（由 Pageables 收敛）。
 */
@Service
@RequiredArgsConstructor
public class AuditQueryService {

    private final AuditLogRepository repo;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public PageResponse<AuditLogRow> query(String actionPrefix,
                                           String actorAccount,
                                           LocalDate dateFrom,
                                           LocalDate dateTo,
                                           int page,
                                           int size) {
        Specification<AuditLog> spec = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (actionPrefix != null && !actionPrefix.isBlank()) {
                ps.add(cb.like(root.get("action"), actionPrefix.trim() + "%"));
            }
            if (actorAccount != null && !actorAccount.isBlank()) {
                ps.add(cb.like(cb.lower(root.get("actorAccount")),
                        "%" + actorAccount.trim().toLowerCase(Locale.ROOT) + "%"));
            }
            if (dateFrom != null) {
                ps.add(cb.greaterThanOrEqualTo(root.get("createdAt"),
                        BusinessTime.startOfDay(dateFrom)));
            }
            if (dateTo != null) {
                // 闭区间：dateTo 当日 23:59:59.999
                OffsetDateTime toExclusive = BusinessTime.startOfDay(dateTo.plusDays(1));
                ps.add(cb.lessThan(root.get("createdAt"), toExclusive));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "createdAt"));
        Page<AuditLog> p = repo.findAll(spec, pageable);
        List<AuditLogRow> items = p.getContent().stream().map(AuditLogRow::of).toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AuditLogDetail detail(long id) {
        return repo.findById(id)
                .map(AuditLogDetail::of)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "审计日志不存在或已归档"));
    }
}
