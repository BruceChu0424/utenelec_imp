package com.uten.imp.features.finance.asset;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.Pageable;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 固定资产折旧 + 长期待摊摊销（C5，依赖 C3 总账）。
 *
 * <p>过账由资产工作台批准的冻结账簿与计划执行，兼容入口禁止删除重建。
 * 原表读取使用企业账有符号凭证事实；原计提、红冲、再次计提均按实际凭证日期保留。</p>
 */
@Service
@RequiredArgsConstructor
public class FixedAssetService {

    private final EntityManager em;
    private final TxSessionVars tx;
    private final com.uten.imp.features.finance.FinanceDocumentAccessPolicy access;

    // ======================== 固定资产 CRUD ========================

    @Transactional(readOnly = true)
    public PageResponse<Map<String, Object>> listAssets(int page, int size) {
        return queryPageMaps("""
                SELECT a.id, a.code, a.name, d.name AS dept, a.expense_style_id, ps.name AS style_name,
                       a.original_value, a.salvage_rate, a.useful_months, a.start_period, a.status, a.remark
                FROM fixed_assets a
                LEFT JOIN departments d ON d.id = a.department_id
                LEFT JOIN payment_styles ps ON ps.id = a.expense_style_id
                WHERE a.is_deleted = false
                ORDER BY a.code, a.id
                """,
                "SELECT COUNT(*) FROM fixed_assets WHERE is_deleted = false",
                page,
                size,
                "id", "code", "name", "dept", "expense_style_id", "style_name",
                "original_value", "salvage_rate", "useful_months", "start_period", "status", "remark");
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public UUID createAsset(Map<String, Object> b) {
        tx.bind();
        if (uuid(b, "expenseStyleId") != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        validatePeriod(str(b, "startPeriod"));
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO fixed_assets (id, code, name, department_id, expense_style_id, original_value,
                                          salvage_rate, useful_months, start_period, status, remark)
                VALUES (:id, :code, :name, :dept, :style, :ov, :sr, :um, :sp, COALESCE(:st,'在用'), :rm)
                """)
                .setParameter("id", id)
                .setParameter("code", req(b, "code"))
                .setParameter("name", req(b, "name"))
                .setParameter("dept", uuid(b, "departmentId"))
                .setParameter("style", uuid(b, "expenseStyleId"))
                .setParameter("ov", dec(b, "originalValue"))
                .setParameter("sr", b.get("salvageRate") == null ? new BigDecimal("0.05") : dec(b, "salvageRate"))
                .setParameter("um", num(b, "usefulMonths"))
                .setParameter("sp", str(b, "startPeriod"))
                .setParameter("st", str(b, "status"))
                .setParameter("rm", str(b, "remark"))
                .executeUpdate();
        return id;
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public void updateAsset(UUID id, Map<String, Object> b) {
        tx.bind();
        if (uuid(b, "expenseStyleId") != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        if (str(b, "startPeriod") != null) validatePeriod(str(b, "startPeriod"));
        int n = em.createNativeQuery("""
                UPDATE fixed_assets SET name=COALESCE(:name,name), department_id=COALESCE(:dept,department_id),
                    expense_style_id=COALESCE(:style,expense_style_id), original_value=COALESCE(:ov,original_value),
                    salvage_rate=COALESCE(:sr,salvage_rate), useful_months=COALESCE(:um,useful_months),
                    start_period=COALESCE(:sp,start_period), status=COALESCE(:st,status),
                    remark=COALESCE(:rm,remark), updated_at=now()
                WHERE id=:id AND is_deleted=false
                """)
                .setParameter("id", id)
                .setParameter("name", str(b, "name"))
                .setParameter("dept", uuid(b, "departmentId"))
                .setParameter("style", uuid(b, "expenseStyleId"))
                .setParameter("ov", dec(b, "originalValue"))
                .setParameter("sr", dec(b, "salvageRate"))
                .setParameter("um", num(b, "usefulMonths"))
                .setParameter("sp", str(b, "startPeriod"))
                .setParameter("st", str(b, "status"))
                .setParameter("rm", str(b, "remark"))
                .executeUpdate();
        if (n == 0) throw new ApiException(ErrorCode.NOT_FOUND, "资产不存在");
    }

    // ======================== 长期待摊 CRUD ========================

    @Transactional(readOnly = true)
    public PageResponse<Map<String, Object>> listDeferred(int page, int size) {
        return queryPageMaps("""
                SELECT a.id, a.code, a.name, a.expense_style_id, ps.name AS style_name,
                       a.total_amount, a.useful_months, a.start_period, a.status, a.remark
                FROM deferred_expenses a
                LEFT JOIN payment_styles ps ON ps.id = a.expense_style_id
                WHERE a.is_deleted = false
                ORDER BY a.code, a.id
                """,
                "SELECT COUNT(*) FROM deferred_expenses WHERE is_deleted = false",
                page,
                size,
                "id", "code", "name", "expense_style_id", "style_name",
                "total_amount", "useful_months", "start_period", "status", "remark");
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public UUID createDeferred(Map<String, Object> b) {
        tx.bind();
        if (uuid(b, "expenseStyleId") != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        validatePeriod(str(b, "startPeriod"));
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO deferred_expenses (id, code, name, expense_style_id, total_amount,
                                               useful_months, start_period, status, remark)
                VALUES (:id, :code, :name, :style, :ta, :um, :sp, COALESCE(:st,'摊销中'), :rm)
                """)
                .setParameter("id", id)
                .setParameter("code", req(b, "code"))
                .setParameter("name", req(b, "name"))
                .setParameter("style", uuid(b, "expenseStyleId"))
                .setParameter("ta", dec(b, "totalAmount"))
                .setParameter("um", num(b, "usefulMonths"))
                .setParameter("sp", str(b, "startPeriod"))
                .setParameter("st", str(b, "status"))
                .setParameter("rm", str(b, "remark"))
                .executeUpdate();
        return id;
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public void updateDeferred(UUID id, Map<String, Object> b) {
        tx.bind();
        if (uuid(b, "expenseStyleId") != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        int n = em.createNativeQuery("""
                UPDATE deferred_expenses SET name=COALESCE(:name,name), expense_style_id=COALESCE(:style,expense_style_id),
                    total_amount=COALESCE(:ta,total_amount), useful_months=COALESCE(:um,useful_months),
                    start_period=COALESCE(:sp,start_period), status=COALESCE(:st,status),
                    remark=COALESCE(:rm,remark), updated_at=now()
                WHERE id=:id AND is_deleted=false
                """)
                .setParameter("id", id)
                .setParameter("name", str(b, "name"))
                .setParameter("style", uuid(b, "expenseStyleId"))
                .setParameter("ta", dec(b, "totalAmount"))
                .setParameter("um", num(b, "usefulMonths"))
                .setParameter("sp", str(b, "startPeriod"))
                .setParameter("st", str(b, "status"))
                .setParameter("rm", str(b, "remark"))
                .executeUpdate();
        if (n == 0) throw new ApiException(ErrorCode.NOT_FOUND, "待摊费用不存在");
    }

    // ======================== 计提 ========================

    /** 历史兼容入口：删除重建已禁用。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public int depreciate(String period) {
        tx.bind();
        throw new ApiException(
                ErrorCode.CONFLICT,
                "旧的删除重建过账方式已停用，请改用「过账批次」功能");
    }

    /** 历史兼容入口：删除重建已禁用。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public int amortize(String period) {
        tx.bind();
        throw new ApiException(
                ErrorCode.CONFLICT,
                "旧的删除重建过账方式已停用，请改用「过账批次」功能");
    }

    // ======================== 报表 ========================

    /** 固定资产折旧清单。 */
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse depreciationSchedule() { return depreciationSchedule(1, 50); }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse depreciationSchedule(int page, int size) {
        return depreciationSchedule(page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse depreciationSchedule(int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        return depreciationSchedule(page,size,options,com.uten.imp.common.time.BusinessTime.today());
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse depreciationSchedule(int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options,java.time.LocalDate dateTo) {
        java.time.LocalDate cutoff=dateTo==null?com.uten.imp.common.time.BusinessTime.today():dateTo;
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return FinanceAssetTemplateReport.query(em,false,false,cutoff,page,size,options);
    }

    /** 长期待摊摊销清单。 */
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse amortizationSchedule() { return amortizationSchedule(1, 50); }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse amortizationSchedule(int page, int size) {
        return amortizationSchedule(page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse amortizationSchedule(int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        return amortizationSchedule(page,size,options,com.uten.imp.common.time.BusinessTime.today());
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse amortizationSchedule(int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options,java.time.LocalDate dateTo) {
        java.time.LocalDate cutoff=dateTo==null?com.uten.imp.common.time.BusinessTime.today():dateTo;
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return FinanceAssetTemplateReport.query(em,true,false,cutoff,page,size,options);
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ReportTableResponse completedDepreciationSchedule(int page,int size,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options,LocalDate dateTo) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return FinanceAssetTemplateReport.query(em,false,true,
                dateTo==null?com.uten.imp.common.time.BusinessTime.today():dateTo,page,size,options);
    }

    // ======================== 工具 ========================

    private PageResponse<Map<String, Object>> queryPageMaps(
            String dataSql,
            String countSql,
            int page,
            int size,
            String... colNames) {
        Pageable pageable = Pageables.of(page, size);
        long total = ((Number) em.createNativeQuery(countSql).getSingleResult()).longValue();
        var query = em.createNativeQuery(dataSql + " LIMIT :__limit OFFSET :__offset")
                .setParameter("__limit", pageable.getPageSize())
                .setParameter("__offset", pageable.getOffset());
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            Map<String, Object> item = new LinkedHashMap<>();
            for (int index = 0; index < row.length && index < colNames.length; index++) {
                item.put(colNames[index], row[index]);
            }
            items.add(item);
        }
        int totalPages = total == 0
                ? 0
                : (int) ((total + pageable.getPageSize() - 1) / pageable.getPageSize());
        return new PageResponse<>(
                items,
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                total,
                totalPages);
    }

    private static void validatePeriod(String p) {
        if (p == null || !p.matches("\\d{4}-\\d{2}")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "期间格式必须为 YYYY-MM（例如 2026-09）");
        }
    }

    private static String req(Map<String, Object> b, String k) {
        String v = str(b, k);
        if (v == null || v.isBlank()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "有必填项没填：" + k);
        return v;
    }

    private static String str(Map<String, Object> b, String k) {
        Object v = b.get(k);
        return v == null ? null : v.toString();
    }

    private static UUID uuid(Map<String, Object> b, String k) {
        String v = str(b, k);
        return (v == null || v.isBlank()) ? null : UUID.fromString(v);
    }

    private static BigDecimal dec(Map<String, Object> b, String k) {
        Object v = b.get(k);
        if (v == null) return null;
        return v instanceof BigDecimal bd ? bd : new BigDecimal(v.toString());
    }

    private static Integer num(Map<String, Object> b, String k) {
        Object v = b.get(k);
        if (v == null) return null;
        try {
            return new BigDecimal(v.toString()).intValueExact();
        } catch (NumberFormatException | ArithmeticException invalid) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "使用月数必须为有效整数");
        }
    }
}
