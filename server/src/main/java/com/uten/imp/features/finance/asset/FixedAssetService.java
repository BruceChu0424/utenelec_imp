package com.uten.imp.features.finance.asset;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportFacet;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.Pageable;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 固定资产折旧 + 长期待摊摊销（C5，依赖 C3 总账）。
 *
 * <p>直线法：月折旧=原值×(1−残值率)/月数；末月=剩余应提（防尾差）。摊销同构（无残值）。
 * 计提幂等：先删该期间 FA_DEP/DA_AMT 凭证与日志，再对全部合格资产重建；
 * 凭证：折旧 借 资产费用科目(默认折旧费)/贷 /152/ 累计折旧；摊销 借 摊销费/贷 /139/ 待摊费用。
 * fa_depreciation_log/da_amortization_log（asset+period 唯一）防重复计提并支撑「已提月数」。</p>
 */
@Service
@RequiredArgsConstructor
public class FixedAssetService {

    private final EntityManager em;
    private final TxSessionVars tx;

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
                "Legacy destructive posting is disabled; use /api/finance/asset-posting-runs");
    }

    /** 历史兼容入口：删除重建已禁用。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public int amortize(String period) {
        tx.bind();
        throw new ApiException(
                ErrorCode.CONFLICT,
                "Legacy destructive posting is disabled; use /api/finance/asset-posting-runs");
    }

    // ======================== 报表 ========================

    /** 固定资产折旧清单。 */
    @Transactional(readOnly = true)
    public ReportTableResponse depreciationSchedule() {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("code", "资产编号", 100),
                ReportColumn.text("name", "资产名称", 180),
                ReportColumn.text("dept", "部门", 110),
                ReportColumn.money("originalValue", "原值"),
                ReportColumn.number("salvageRate", "残值率"),
                ReportColumn.number("usefulMonths", "年限(月)"),
                ReportColumn.text("startPeriod", "开始期间", 90),
                ReportColumn.money("monthlyDep", "月折旧"),
                ReportColumn.number("postedMonths", "已提月数"),
                ReportColumn.money("accumDep", "累计折旧"),
                ReportColumn.money("netValue", "净值"),
                ReportColumn.text("status", "状态", 80));
        List<Map<String, Object>> rows = queryMaps("""
                SELECT a.code, a.name, COALESCE(d.name,'') AS dept, a.original_value, a.salvage_rate,
                       a.useful_months, a.start_period,
                       ROUND(a.original_value * (1 - a.salvage_rate) / a.useful_months, 2) AS monthly_dep,
                       (SELECT COUNT(*) FROM fa_depreciation_log l WHERE l.asset_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false) AS posted_months,
                       (SELECT COALESCE(SUM(l.amount),0) FROM fa_depreciation_log l WHERE l.asset_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false) AS accum_dep,
                       ROUND(a.original_value - (SELECT COALESCE(SUM(l.amount),0) FROM fa_depreciation_log l WHERE l.asset_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false), 2) AS net_value,
                       a.status
                FROM fixed_assets a LEFT JOIN departments d ON d.id = a.department_id
                WHERE a.is_deleted = false ORDER BY a.code
                """, "code", "name", "dept", "original_value", "salvage_rate", "useful_months",
                "start_period", "monthly_dep", "posted_months", "accum_dep", "net_value", "status").stream().map(m -> {
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("code", m.get("code"));
            r.put("name", m.get("name"));
            r.put("dept", m.get("dept"));
            r.put("originalValue", m.get("original_value"));
            r.put("salvageRate", m.get("salvage_rate"));
            r.put("usefulMonths", m.get("useful_months"));
            r.put("startPeriod", m.get("start_period"));
            r.put("monthlyDep", m.get("monthly_dep"));
            r.put("postedMonths", m.get("posted_months"));
            r.put("accumDep", m.get("accum_dep"));
            r.put("netValue", m.get("net_value"));
            r.put("status", m.get("status"));
            return r;
        }).toList();
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, Math.max(rows.size(), 1), rows.size(), 1);
    }

    /** 长期待摊摊销清单。 */
    @Transactional(readOnly = true)
    public ReportTableResponse amortizationSchedule() {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("code", "编号", 100),
                ReportColumn.text("name", "项目名称", 180),
                ReportColumn.money("totalAmount", "待摊总额"),
                ReportColumn.number("usefulMonths", "摊销月数"),
                ReportColumn.text("startPeriod", "开始期间", 90),
                ReportColumn.money("monthlyAmt", "月摊销"),
                ReportColumn.number("postedMonths", "已摊月数"),
                ReportColumn.money("accumAmt", "累计摊销"),
                ReportColumn.money("remain", "待摊余额"),
                ReportColumn.text("status", "状态", 90));
        List<Map<String, Object>> rows = queryMaps("""
                SELECT a.code, a.name, a.total_amount, a.useful_months, a.start_period,
                       ROUND(a.total_amount / a.useful_months, 2) AS monthly_amt,
                       (SELECT COUNT(*) FROM da_amortization_log l WHERE l.deferred_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false) AS posted_months,
                       (SELECT COALESCE(SUM(l.amount),0) FROM da_amortization_log l WHERE l.deferred_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false) AS accum_amt,
                       ROUND(a.total_amount - (SELECT COALESCE(SUM(l.amount),0) FROM da_amortization_log l WHERE l.deferred_id=a.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false), 2) AS remain,
                       a.status
                FROM deferred_expenses a
                WHERE a.is_deleted = false ORDER BY a.code
                """, "code", "name", "total_amount", "useful_months", "start_period", "monthly_amt",
                "posted_months", "accum_amt", "remain", "status").stream().map(m -> {
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("code", m.get("code"));
            r.put("name", m.get("name"));
            r.put("totalAmount", m.get("total_amount"));
            r.put("usefulMonths", m.get("useful_months"));
            r.put("startPeriod", m.get("start_period"));
            r.put("monthlyAmt", m.get("monthly_amt"));
            r.put("postedMonths", m.get("posted_months"));
            r.put("accumAmt", m.get("accum_amt"));
            r.put("remain", m.get("remain"));
            r.put("status", m.get("status"));
            return r;
        }).toList();
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, Math.max(rows.size(), 1), rows.size(), 1);
    }

    // ======================== 工具 ========================

    private List<Map<String, Object>> queryMaps(String sql, String... colNames) {
        var q = em.createNativeQuery(sql);
        @SuppressWarnings("unchecked")
        List<Object[]> rs = q.getResultList();
        List<Map<String, Object>> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < r.length && i < colNames.length; i++) m.put(colNames[i], r[i]);
            out.add(m);
        }
        return out;
    }

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
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "期间格式 YYYY-MM");
        }
    }

    private static String req(Map<String, Object> b, String k) {
        String v = str(b, k);
        if (v == null || v.isBlank()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少必填字段 " + k);
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
        return v instanceof Number n ? n.intValue() : Integer.valueOf(v.toString());
    }
}
