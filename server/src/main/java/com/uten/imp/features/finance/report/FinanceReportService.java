package com.uten.imp.features.finance.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.BiFunction;

/**
 * 钱流报表查询服务（finance_report:view）—— 镜像销售/采购 {@code ReportTableResponse} 范式。
 *
 * <p>22 张报表（按用户列规格），分 5 组（前端 5 张卡）：
 * <ol>
 *   <li><b>应收应付</b>：Z 总览（{@link #arApOverview}，前端左分类树+右表）、A/C 明细（{@link #arApDetail}，
 *       direction=AR/AP）、B/D 汇总（{@link #arApSummary}）。</li>
 *   <li><b>明细报表</b>：E 销售收款 / G 采购付款 / M 一般费用 / O 其它收入 / V 费用冲销（各 detail）。</li>
 *   <li><b>汇总报表</b>：F 销售收款 / H 采购付款 / N 一般费用 / P 其它收入（各 summary）。</li>
 *   <li><b>往来对帐单</b>：I/K 流水（{@link #partyStatementFlow}）、J/L 明细（{@link #partyStatementDetail}）、
 *       X 年度（{@link #partyAnnualStatement}）—— side=AR/AP、带 partyId。</li>
 *   <li><b>账户流水</b>：S 帐户进出流水（{@link #accountStatement}，滚动余额）；Q/R 银行存取款（空表）。</li>
 * </ol>
 *
 * <p>人员名：maker/approver（Sys_Operator 冻结 *_name，不入 employees）→ {@code COALESCE(em.full_name, t.*_name)}；
 * operator/work（B_Worker stub）→ {@code COALESCE(em_op.full_name, t.operator_name)} + 子类括注（legacy_category）。
 * JOIN 范式以 {@code em.id=t.*_id} 为准，仅 current UUID 为空时回退 legacy_id。
 *
 * <p>_null 参数类型坑_：可选过滤一律 {@code CAST(:param AS 类型) IS NULL OR ...}（见 MEMORY）。
 *
 * <p>明细表：一行=单里一样货品/一笔（同单号可重复）；汇总表：一行=一整张单（单号唯一）。
 */
@Service
@RequiredArgsConstructor
public class FinanceReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");
    private static final String FINANCE_REPORT_OWNERS = "financeReportOwners";
    private static final NativeReadScope COMPANY_WIDE_DOCUMENT_SCOPE =
            new NativeReadScope("1=1", null, java.util.Set.of());

    private final EntityManager em;
    private final FinanceDocumentAccessPolicy access;
    private final SystemSettingsService settings;
    private final com.uten.imp.features.finance.statement.FinanceStatementService statementService;
    private final com.uten.imp.features.finance.cost.FinanceCostService costService;
    private final com.uten.imp.features.finance.gl.GlReportService glReportService;
    private final com.uten.imp.features.finance.asset.FixedAssetService fixedAssetService;

    // ======================== 通用执行器（镜像销售/采购） ========================

    @Transactional(readOnly = true)
    private ReportTableResponse execute(List<ReportColumn> columns, String dataSelect, String fromJoin,
                                        WhereBuilder mainWhere, String orderBy, List<FacetSpec> specs,
                                        Map<String, String> activeFacets, int page, int size,
                                        String sort, String order) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        List<WhereBuilder.Clause> facetClauses = new ArrayList<>();
        if (activeFacets != null) {
            for (Map.Entry<String, String> e : activeFacets.entrySet()) {
                FacetSpec spec = specs.stream().filter(s -> s.key().equals(e.getKey())).findFirst().orElse(null);
                if (spec != null && e.getValue() != null && !e.getValue().isBlank()) {
                    facetClauses.add(facetClause(spec, e.getValue()));
                }
            }
        }
        WhereBuilder.Built full = mainWhere.build(facetClauses);
        WhereBuilder.Built baseB = mainWhere.build(null);

        // 列排序：sort 必须命中 columns 的 key（白名单，防 SQL 注入）；命中则按投影别名排序，否则用默认 orderBy。
        var sortKeys = new java.util.HashSet<String>();
        for (ReportColumn c : columns) sortKeys.add(c.key());
        String effectiveOrderBy = ReportSort.resolveOrderBy(sort, order, orderBy, sortKeys);

        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql()
                + " ORDER BY " + effectiveOrderBy + " LIMIT :__limit OFFSET :__offset");
        full.params().forEach(dataQ::setParameter);
        dataQ.setParameter("__limit", safeSize);
        dataQ.setParameter("__offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < columns.size(); i++) m.put(columns.get(i).key(), norm(r[i]));
            items.add(m);
        }

        var countQ = em.createNativeQuery("SELECT COUNT(*) " + fromJoin + " " + full.sql());
        full.params().forEach(countQ::setParameter);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

        Map<String, List<ReportFacet>> facets = new LinkedHashMap<>();
        for (FacetSpec spec : specs) {
            var fq = em.createNativeQuery("SELECT " + spec.selectExpr() + ", COUNT(*) AS cnt " + fromJoin + " "
                    + baseB.sql() + " GROUP BY " + spec.groupExpr() + " ORDER BY cnt DESC LIMIT 50");
            baseB.params().forEach(fq::setParameter);
            @SuppressWarnings("unchecked")
            List<Object[]> frs = fq.getResultList();
            List<ReportFacet> buckets = new ArrayList<>();
            for (Object[] fr : frs) {
                Object v = fr[0];
                String val = (v == null) ? ReportTableResponse.NULL_FACET : Objects.toString(v);
                String lbl = (v == null) ? "(空)" : (fr[1] == null ? null : fr[1].toString());
                long cnt = ((Number) fr[2]).longValue();
                buckets.add(new ReportFacet(val, lbl, cnt));
            }
            facets.put(spec.key(), buckets);
        }

        // 隐藏元数据列（key 以 "__" 开头，如 __srcId）：不进返回的 columns（前端不渲染、导出不含），但行 Map 已 put 其值。
        // 表格下方合计：与列表用同一份 full（日期/facet/关键字 + 对象级授权谓词）在**整个结果集**
        // 上聚合，与翻到第几页无关；派生表不带 LIMIT/OFFSET，所以绝不会出现「只合计当前页」。
        List<com.uten.imp.common.report.ReportTotal> totals =
                com.uten.imp.common.report.ReportTotalsCalculator.compute(
                        em, dataSelect, fromJoin, full.sql(), full.params(),
                        reportTotalSpecs(columns, columns));

        List<ReportColumn> visible = columns.stream().filter(c -> !c.key().startsWith("__")).toList();
        return new ReportTableResponse(visible, items, facets, safePage, safeSize, total, totalPages, totals);
    }

    /**
     * 把列定义里 {@code totaled(...)} 声明的合计翻译成聚合规格。
     *
     * <p>{@code emitted} = 实际下发给前端的列（脱敏后）——被 priceMasked 拿掉的金额列不在其中，
     * 合计自然也不会出现，无需另写门控。{@code projected} = dataSelect 真正投影的列，
     * 用来确认分组列（单位名/币种名）确实在派生表里。
     *
     * <p><b>声明了分组列却没投影时整项丢弃</b>，绝不退回「不分组」——那等于跨单位/跨币种相加。
     */
    private static List<com.uten.imp.common.report.ReportTotalsCalculator.Spec> reportTotalSpecs(
            List<ReportColumn> emitted, List<ReportColumn> projected) {
        java.util.Set<String> present = new java.util.HashSet<>();
        for (ReportColumn c : projected) present.add(c.key());
        List<com.uten.imp.common.report.ReportTotalsCalculator.Spec> specs = new ArrayList<>();
        for (ReportColumn c : emitted) {
            String label = c.totalLabel();
            if (label == null || label.isBlank()) continue;
            String g = c.totalGroupKey();
            if (g != null && !present.contains(g)) continue;
            specs.add(new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                    c.key(), label, c.type(), g));
        }
        return specs;
    }

    private static Object norm(Object v) {
        if (v == null) return null;
        if (v instanceof java.sql.Date d) return d.toLocalDate().toString();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate().toString();
        if (v instanceof java.time.OffsetDateTime odt) return odt.toLocalDate().toString();
        if (v instanceof BigDecimal || v instanceof Boolean || v instanceof Number) return v;
        if (v instanceof UUID u) return u.toString();
        return v.toString();
    }

    private static WhereBuilder.Clause facetClause(FacetSpec spec, String value) {
        String p = "facet_" + spec.key();
        if (ReportTableResponse.NULL_FACET.equals(value)) {
            return new WhereBuilder.Clause("(" + spec.filterExpr() + ") IS NULL", null, null);
        }
        return switch (spec.filterType()) {
            case "uuid"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS uuid)", p, UUID.fromString(value));
            case "int"   -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS int)", p, Integer.valueOf(value));
            case "bool"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS boolean)", p, Boolean.valueOf(value));
            default      -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS text)", p, value);
        };
    }

    // ======================== ① 应收应付 Z / A·C / B·D ========================

    /** Z 应收应付总览（前端左分类树+右表；这里返回每个往来单位的 AR/AP 余额 + 电话/地址/类别）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse arApOverview(LocalDate dateFrom, LocalDate dateTo, String displayMode,
                                           String keyword, String categoryType, UUID categoryId, int page, int size) {
        requireCompanyWideReportAccess();
        return arApOverviewAuthorized(
                dateFrom, dateTo, displayMode, keyword, categoryType, categoryId, page, size);
    }

    private ReportTableResponse arApOverviewAuthorized(
            LocalDate dateFrom, LocalDate dateTo, String displayMode,
            String keyword, String categoryType, UUID categoryId, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("partyName", "往来单位", 220),
                ReportColumn.text("partyType", "类型", 80),
                // 一行一往来单位，金额取 ar_ap_ledger.amount_balance（= 立账本币 − 已核销，恒为人民币），
                // 跨单位相加得到的正是「全部客户应收合计 / 全部供应商应付合计」，无币种维度。
                ReportColumn.money("receivable", "应收金额").totaled("合计应收金额"),
                ReportColumn.money("payable", "应付金额").totaled("合计应付金额"),
                ReportColumn.text("phone", "电话", 130),
                ReportColumn.text("address", "联系地址", 220));
        // 客户类别/供应商类别按 category_id 下溯（递归 CTE）；categoryType 决定查 clients 还是 suppliers。
        boolean filterClient = "CLIENT".equalsIgnoreCase(categoryType) && categoryId != null;
        boolean filterSupplier = "SUPPLIER".equalsIgnoreCase(categoryType) && categoryId != null;
        String clientCatFilter = filterClient
                ? " AND c.category_id IN (WITH RECURSIVE d AS (SELECT id FROM client_categories WHERE id=:catId "
                + "UNION ALL SELECT cc.id FROM client_categories cc JOIN d ON cc.parent_id=d.id) SELECT id FROM d)" : "";
        String supplierCatFilter = filterSupplier
                ? " AND s.category_id IN (WITH RECURSIVE d AS (SELECT id FROM supplier_categories WHERE id=:catId "
                + "UNION ALL SELECT sc.id FROM supplier_categories sc JOIN d ON sc.parent_id=d.id) SELECT id FROM d)" : "";
        // 仅当指定 categoryType 时显示对应侧（否则两侧都显示）
        boolean onlyClient = filterClient;
        boolean onlySupplier = filterSupplier;
        boolean showClient = !"SUPPLIER".equalsIgnoreCase(categoryType);
        boolean showSupplier = !"CLIENT".equalsIgnoreCase(categoryType);

        StringBuilder union = new StringBuilder();
        if (showClient) {
            union.append("SELECT c.name AS partyName, COALESCE(c.code,'') AS partyCode, '客户' AS partyType, COALESCE(ar.bal,0) AS receivable, 0 AS payable, "
                    + "COALESCE(c.phone,'') AS phone, COALESCE(c.address,'') AS address FROM clients c "
                    + "LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal FROM ar_ap_ledger "
                    + "WHERE direction='AR' AND is_deleted=false AND status=1"
                    + dateClause("bill_date") + " GROUP BY client_id) ar ON ar.client_id=c.id "
                    + "WHERE COALESCE(c.is_deleted,false)=false" + clientCatFilter);
            if (showSupplier) union.append(" UNION ALL ");
        }
        if (showSupplier) {
            union.append("SELECT s.name AS partyName, COALESCE(s.code,'') AS partyCode, '供应商' AS partyType, 0 AS receivable, COALESCE(ap.bal,0) AS payable, "
                    + "COALESCE(s.phone,'') AS phone, COALESCE(s.address,'') AS address FROM suppliers s "
                    + "LEFT JOIN (SELECT supplier_id, SUM(amount_balance) AS bal FROM ar_ap_ledger "
                    + "WHERE direction='AP' AND is_deleted=false AND status=1"
                    + dateClause("bill_date") + " GROUP BY supplier_id) ap ON ap.supplier_id=s.id "
                    + "WHERE COALESCE(s.is_deleted,false)=false" + supplierCatFilter);
        }
        // 显示方式过滤
        String mode = displayMode == null ? "" : displayMode.trim();
        String having = switch (mode) {
            case "AR_ONLY" -> " WHERE receivable <> 0";
            case "AP_ONLY" -> " WHERE payable <> 0";
            case "ANY" -> " WHERE receivable <> 0 OR payable <> 0";
            default -> "";
        };
        // keyword 过滤
        WhereBuilder w = new WhereBuilder(having + (having.isEmpty() ? "WHERE" : " AND")
                + (keyword == null || keyword.isBlank()
                ? " TRUE"
                : " (LOWER(COALESCE(partyName,'')) LIKE LOWER(:kw)"
                + " OR LOWER(COALESCE(partyCode,'')) LIKE LOWER(:kw))"));
        // 包成一个子查询，便于 count + 分页
        // partyCode 只用于搜索，放在内部投影最后；executeOverview 仍只映射前 6 列，
        // 因此对外 ReportTableResponse 列契约不变。
        String dataSelect = "SELECT partyName, partyType, receivable, payable, phone, address, partyCode FROM ("
                + union + ") z";
        String fromJoin = "";
        if (keyword != null && !keyword.isBlank()) {
            w.add("", "kw", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        // arApOverview 用独立查询（带 category 递归 CTE 参数），不走通用 execute 的 facet；这里手写计数+分页
        return executeOverview(cols, dataSelect, fromJoin, w, dateFrom, dateTo, keyword, categoryId,
                onlyClient || onlySupplier ? categoryId : null, page, size);
    }

    /**
     * 应收应付统一搜索的公司级分类定位。
     *
     * <p>返回“往来单位类型 + 分类 id”的去重集合，而不是主档明细。权限与
     * {@link #arApOverview} 相同：必须可查看钱流报表，且服务层要求公司级
     * {@code finance:view:all}。因此财务用户即使没有 {@code client:view:all}，定位范围
     * 仍与右侧公司级报表一致，不会被客户主档 OwnerVisibility 意外裁剪。
     */
    @Transactional(readOnly = true)
    public PageResponse<ArApPartyLocation> arApPartyLocations(
            String keyword, int page, int size) {
        requireCompanyWideReportAccess();
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 100);
        String normalized = keyword == null ? "" : keyword.trim().toLowerCase(Locale.ROOT);
        if (normalized.isEmpty()) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }

        String locations = """
                SELECT 'CLIENT' AS party_type, c.category_id
                  FROM clients c
                 WHERE COALESCE(c.is_deleted,false)=false
                   AND (LOWER(COALESCE(c.name,'')) LIKE :locationKw
                     OR LOWER(COALESCE(c.code,'')) LIKE :locationKw)
                UNION
                SELECT 'SUPPLIER' AS party_type, s.category_id
                  FROM suppliers s
                 WHERE COALESCE(s.is_deleted,false)=false
                   AND (LOWER(COALESCE(s.name,'')) LIKE :locationKw
                     OR LOWER(COALESCE(s.code,'')) LIKE :locationKw)
                """;
        long offset = (long) (safePage - 1) * safeSize;
        var dataQuery = em.createNativeQuery(
                "SELECT party_type, category_id FROM (" + locations + ") party_locations "
                        + "ORDER BY party_type ASC, category_id ASC NULLS LAST "
                        + "LIMIT :locationLimit OFFSET :locationOffset");
        dataQuery.setParameter("locationKw", "%" + normalized + "%");
        dataQuery.setParameter("locationLimit", safeSize);
        dataQuery.setParameter("locationOffset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQuery.getResultList();
        List<ArApPartyLocation> items = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String partyType = Objects.toString(row[0], "");
            UUID categoryId = row[1] == null ? null : parseUuid(row[1].toString());
            items.add(new ArApPartyLocation(partyType, categoryId));
        }

        var countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + locations + ") party_locations");
        countQuery.setParameter("locationKw", "%" + normalized + "%");
        long total = ((Number) countQuery.getSingleResult()).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    /** arApOverview 专用：带 category 递归 CTE 参数 + 计数 + 分页（无 facet）。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeOverview(List<ReportColumn> cols, String dataSelect, String fromJoin,
                                                WhereBuilder w, LocalDate dateFrom, LocalDate dateTo,
                                                String keyword, UUID catId, UUID catParam, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        WhereBuilder.Built full = w.build(null);
        var dataQ = em.createNativeQuery(dataSelect + " " + full.sql()
                + " ORDER BY partyType, partyName LIMIT :__limit OFFSET :__offset");
        full.params().forEach(dataQ::setParameter);
        dataQ.setParameter("fromDate", dateFrom);
        dataQ.setParameter("toDate", dateTo);
        if (catParam != null) dataQ.setParameter("catId", catParam);
        dataQ.setParameter("__limit", safeSize);
        dataQ.setParameter("__offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("partyName", norm(r[0])); m.put("partyType", norm(r[1]));
            m.put("receivable", norm(r[2])); m.put("payable", norm(r[3]));
            m.put("phone", norm(r[4])); m.put("address", norm(r[5]));
            items.add(m);
        }
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM (" + dataSelect + ") z " + full.sql());
        full.params().forEach(countQ::setParameter);
        countQ.setParameter("fromDate", dateFrom);
        countQ.setParameter("toDate", dateTo);
        if (catParam != null) countQ.setParameter("catId", catParam);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        // 合计：与列表同一段 dataSelect + 同一份 where（日期/显示方式/关键字/分类下溯），
        // 派生表不带 LIMIT/OFFSET，所以覆盖整个结果集而不是当前这一页。
        List<com.uten.imp.common.report.ReportTotal> totals = com.uten.imp.common.report.ReportTotalsCalculator.compute(
                em, dataSelect, fromJoin, full.sql(),
                q -> {
                    full.params().forEach(q::setParameter);
                    q.setParameter("fromDate", dateFrom);
                    q.setParameter("toDate", dateTo);
                    if (catParam != null) q.setParameter("catId", catParam);
                },
                reportTotalSpecs(cols, cols));
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages, totals);
    }

    /** A/C 应收/应付明细（ar_ap_ledger，direction=AR 给 A / AP 给 C）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse arApDetail(String direction, String billNo, UUID partyId, Boolean settled,
                                          LocalDate dateFrom, LocalDate dateTo, String keyword,
                                          Map<String, String> facets, int page, int size, String sort, String order) {
        requireCompanyWideReportAccess();
        return arApDetailAuthorized(direction, billNo, partyId, settled, dateFrom, dateTo,
                keyword, facets, page, size, sort, order);
    }

    private ReportTableResponse arApDetailAuthorized(
            String direction, String billNo, UUID partyId, Boolean settled,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order) {
        String dir = normalizeDirection(direction);
        boolean isAR = "AR".equals(dir);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "立帐单号", 150),
                ReportColumn.text("sourceDocNo", "来源单号", 150),
                ReportColumn.text("salesOrderNos", "销售订单号", 190),
                ReportColumn.text("partyName", isAR ? "客户名称" : "供应商", 180),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.date("dueDate", isAR ? "收款限期" : "付款限期"),
                ReportColumn.text("settlementStyle", "结帐方式", 90),
                ReportColumn.bool("settled", isAR ? "是否已收款" : "是否已付款"),
                ReportColumn.text("currencyCode", "币别", 80),
                // 汇率是比率，相加无意义，不声明合计。
                ReportColumn.number("rate", "汇率"),
                // 一行 = 一条立账台账：原币列按币别分组（绝不跨币种相加），人民币列本就同币不分组。
                ReportColumn.money("amountOriginal", isAR ? "应收款金额" : "应付款金额")
                        .totaled(isAR ? "合计应收款金额" : "合计应付款金额", "currencyCode"),
                ReportColumn.money("receivedOriginal", isAR ? "已收款金额" : "已付款金额")
                        .totaled(isAR ? "合计已收款金额" : "合计已付款金额", "currencyCode"),
                ReportColumn.money("writeOffOriginal", "费用冲销金额").totaled("合计费用冲销金额", "currencyCode"),
                ReportColumn.money("offsetOriginal", "往来抵销金额").totaled("合计往来抵销金额", "currencyCode"),
                ReportColumn.money("balanceOriginal", isAR ? "未收金额" : "未付金额")
                        .totaled(isAR ? "合计未收金额" : "合计未付金额", "currencyCode"),
                ReportColumn.money("amountLocal", "立账人民币").totaled("合计立账人民币"),
                ReportColumn.money("receivedLocal", isAR ? "到账人民币" : "付款人民币")
                        .totaled(isAR ? "合计到账人民币" : "合计付款人民币"),
                ReportColumn.money("writeOffLocal", "费用冲销人民币").totaled("合计费用冲销人民币"),
                ReportColumn.money("offsetLocal", "往来抵销人民币").totaled("合计往来抵销人民币"),
                ReportColumn.money("balanceLocal", "未结人民币").totaled("合计未结人民币"),
                ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT l.bill_no AS "billNo", l.source_doc_no AS "sourceDocNo",
                       refs.sales_order_nos AS "salesOrderNos",
                       COALESCE(c.name, s.name) AS "partyName", l.bill_date AS "billDate",
                       l.due_date AS "dueDate",
                       CASE l.settlement_style_legacy
                           WHEN 1 THEN '现金' WHEN 2 THEN '提货' WHEN 3 THEN '代付'
                           WHEN 4 THEN '支票' WHEN 6 THEN '月结' WHEN 7 THEN '垫付'
                           WHEN 8 THEN '汇款' WHEN 10 THEN '代收' ELSE '未设置'
                       END AS "settlementStyle",
                       l.is_settled AS "settled", cur.code AS "currencyCode", l.exchange_rate AS "rate",
                       l.amount_original AS "amountOriginal",
                       l.amount_received_original AS "receivedOriginal",
                       l.amount_write_off_original AS "writeOffOriginal",
                       l.amount_offset_original AS "offsetOriginal",
                       l.amount_balance_original AS "balanceOriginal",
                       l.amount_original_local AS "amountLocal",
                       l.amount_received_local AS "receivedLocal",
                       l.amount_write_off_local AS "writeOffLocal",
                       l.amount_offset_local AS "offsetLocal",
                       l.amount_balance AS "balanceLocal", l.remark AS "remark"
                """;
        String fromJoin = """
                FROM ar_ap_ledger l
                LEFT JOIN clients c ON c.id=l.client_id
                LEFT JOIN suppliers s ON s.id=l.supplier_id
                LEFT JOIN currencies cur ON cur.id=l.currency_id
                LEFT JOIN LATERAL (
                    SELECT string_agg(r.source_no, '、' ORDER BY r.source_no) AS sales_order_nos
                    FROM ar_ap_source_refs r
                    WHERE r.ledger_id=l.id AND r.source_type='SALES_ORDER'
                ) refs ON TRUE
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(l.is_deleted,false)=false AND l.direction=:dir AND l.status=1");
        w.add("", "dir", dir);
        if (billNo != null && !billNo.isBlank()) w.add("l.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (partyId != null) w.add(isAR ? "l.client_id=:pid" : "l.supplier_id=:pid", "pid", partyId);
        if (settled != null) w.add("l.is_settled=:settled", "settled", settled);
        if (dateFrom != null) w.add("l.bill_date>=:dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("l.bill_date<=:dateTo", "dateTo", dateTo);
        if (keyword != null && !keyword.isBlank())
            w.add("(LOWER(l.bill_no) LIKE LOWER(:kw) OR LOWER(COALESCE(l.source_doc_no,'')) LIKE LOWER(:kw) "
                    + "OR LOWER(COALESCE(c.name,s.name)) LIKE LOWER(:kw) "
                    + "OR LOWER(COALESCE(refs.sales_order_nos,'')) LIKE LOWER(:kw))",
                    "kw", "%" + keyword.toLowerCase() + "%");
        List<FacetSpec> specs = List.of(
                new FacetSpec("settled", "l.is_settled AS v, CASE WHEN l.is_settled THEN '已收/付' ELSE '未收/付' END AS lbl", "l.is_settled", "l.is_settled", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "l.bill_date DESC, l.bill_no", specs, facets, page, size, sort, order);
    }

    /**
     * 已审核销售订单待收计划（经营视图，不是会计 AR）。订单审核后即可供财务跟踪；
     * 发运金额来自不可变 ar_ap_source_refs，正式应收及收款仍以 ar_ap_ledger 为准，避免重复立账。
     */
    @Transactional(readOnly = true)
    public ReportTableResponse salesOrderReceivablePlan(
            String billNo, UUID clientId, LocalDate dateFrom, LocalDate dateTo,
            String keyword, int page, int size, String sort, String order) {
        requireCompanyWideReportAccess();
        return salesOrderReceivablePlanAuthorized(
                billNo, clientId, dateFrom, dateTo, keyword, page, size, sort, order);
    }

    private ReportTableResponse salesOrderReceivablePlanAuthorized(
            String billNo, UUID clientId, LocalDate dateFrom, LocalDate dateTo,
            String keyword, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("orderNo", "销售订单号", 160),
                ReportColumn.date("orderDate", "订单日期"),
                ReportColumn.text("clientName", "客户名称", 180),
                ReportColumn.text("settlement", "结账方式", 120),
                ReportColumn.date("expectedDueDate", "预计收款日期"),
                ReportColumn.text("shippingPolicy", "发运策略", 110),
                ReportColumn.text("currencyCode", "币别", 80),
                // 一行 = 一张已审销售订单；三列均为该订单自身的原币金额，按币别分组相加。
                ReportColumn.money("orderOriginal", "订单原币金额").totaled("合计订单原币金额", "currencyCode"),
                ReportColumn.money("recognizedOriginal", "已发运立账原币")
                        .totaled("合计已发运立账原币", "currencyCode"),
                ReportColumn.money("expectedOriginal", "未发运待收原币")
                        .totaled("合计未发运待收原币", "currencyCode"),
                ReportColumn.text("planStatus", "待收计划状态", 120),
                ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT sales_order.bill_no AS "orderNo", sales_order.bill_date AS "orderDate",
                       client.name AS "clientName",
                       CASE COALESCE(sales_order.payment_style_id,client.price_style)
                           WHEN 1 THEN '现金' WHEN 2 THEN '提货' WHEN 3 THEN '代付'
                           WHEN 4 THEN '支票' WHEN 6 THEN '月结' WHEN 7 THEN '垫付'
                           WHEN 8 THEN '汇款' WHEN 10 THEN '代收' ELSE '未设置' END AS "settlement",
                       sales_order.bill_date + GREATEST(COALESCE(client.tday,0),0) AS "expectedDueDate",
                       CASE sales_order.shipment_policy
                           WHEN 'ALLOW_PARTIAL' THEN '允许分批'
                           WHEN 'REQUIRE_COMPLETE' THEN '整单齐套'
                           WHEN 'CUSTOMER_CONFIRM' THEN '逐批客户确认'
                           ELSE '历史未指定' END AS "shippingPolicy",
                       currency.code AS "currencyCode",
                       sales_order.total_original AS "orderOriginal",
                       COALESCE(recognized.amount_original,0) AS "recognizedOriginal",
                       GREATEST(COALESCE(sales_order.total_original,0)-COALESCE(recognized.amount_original,0),0)
                           AS "expectedOriginal",
                        CASE
                            WHEN COALESCE(recognized.amount_original,0)=0 THEN '待发运'
                           WHEN COALESCE(recognized.amount_original,0)<COALESCE(sales_order.total_original,0)
                               THEN '部分发运'
                           ELSE '已全部立账' END AS "planStatus",
                       sales_order.remark AS "remark"
                """;
        String fromJoin = """
                FROM sales_orders sales_order
                JOIN clients client ON client.id=sales_order.client_id
                LEFT JOIN currencies currency ON currency.id=sales_order.currency_id
                LEFT JOIN LATERAL (
                    SELECT SUM(source.amount_original) AS amount_original
                    FROM ar_ap_source_refs source
                    JOIN ar_ap_ledger ledger ON ledger.id=source.ledger_id
                    WHERE source.source_type='SALES_ORDER'
                      AND source.source_id=sales_order.id
                      AND ledger.direction='AR'
                      AND ledger.source_doc_type='SALES_SHIPMENT'
                      AND ledger.status=1
                      AND COALESCE(ledger.is_deleted,false)=false
                ) recognized ON TRUE
                """;
        WhereBuilder w = new WhereBuilder("WHERE sales_order.status=1"
                + " AND COALESCE(sales_order.is_deleted,false)=false"
                + " AND COALESCE(client.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) {
            w.add("sales_order.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        }
        if (clientId != null) w.add("sales_order.client_id=:clientId", "clientId", clientId);
        if (dateFrom != null) w.add("sales_order.bill_date>=:dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("sales_order.bill_date<=:dateTo", "dateTo", dateTo);
        if (keyword != null && !keyword.isBlank()) {
            w.add("(LOWER(sales_order.bill_no) LIKE LOWER(:kw)"
                            + " OR LOWER(COALESCE(client.name,'')) LIKE LOWER(:kw)"
                            + " OR LOWER(COALESCE(client.full_name,'')) LIKE LOWER(:kw))",
                    "kw", "%" + keyword.toLowerCase() + "%");
        }
        return execute(cols, dataSelect, fromJoin, w, "sales_order.bill_date DESC,sales_order.bill_no",
                List.of(), Map.of(), page, size, sort, order);
    }

    /** B/D 应收/应付汇总（按往来单位 GROUP BY，含期初/本期立帐/核销/期末余额）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse arApSummary(String direction, LocalDate dateFrom, LocalDate dateTo, String keyword,
                                          Map<String, String> facets, int page, int size, String sort, String order) {
        requireCompanyWideReportAccess();
        return arApSummaryAuthorized(
                direction, dateFrom, dateTo, keyword, facets, page, size, sort, order);
    }

    private ReportTableResponse arApSummaryAuthorized(
            String direction, LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order) {
        String dir = normalizeDirection(direction);
        LocalDate from = dateFrom != null ? dateFrom : LocalDate.of(2010, 1, 1);
        LocalDate to = dateTo != null ? dateTo : BusinessTime.today();
        return "AR".equals(dir)
                ? receivableSummaryAuthorized(keyword, from, to, page, size)
                : payableSummaryAuthorized(keyword, from, to, facets, page, size, sort, order);
    }

    /** B 应收款汇总（按客户；期初/发货/回款/退货/期末 用「立帐 − 收款」时序一致口径，保证 期初+发货+退货−回款=期末）。
     *  附件6 口径（2026-07-29 补全）：结算期限（PStyle+TDay 渲染）/铺底额（clients.credit_floor）/
     *  超出铺底额（应收余额−铺底额，V443 起保留负数；未设置铺底按 0）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receivableSummary(String keyword, LocalDate from, LocalDate to, int page, int size) {
        requireCompanyWideReportAccess();
        return receivableSummaryAuthorized(keyword, from, to, page, size);
    }

    private ReportTableResponse receivableSummaryAuthorized(
            String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("partyCode", "客户编号", 110),
                ReportColumn.text("partyName", "客户简称", 160),
                ReportColumn.text("partyFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100),
                ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100),
                ReportColumn.text("district", "所属地区", 110),
                ReportColumn.text("salesPaymentType", "货款类型", 100),
                ReportColumn.text("settlement", "结算期限", 130),
                // 铺底额是客户主档上的授信上限（政策属性，非本期发生额/余额），跨客户求和不是账上的任何一个数，
                // 不声明合计。
                ReportColumn.money("creditFloor", "铺底额"),
                // 一行一客户、全部为人民币口径：期初+发货+退货−回款−冲销+汇兑差额=期末，
                // 该恒等式在合计行上同样成立，正是财务核对的用法。
                ReportColumn.money("prevBalance", "上月余额").totaled("合计上月余额"),
                ReportColumn.money("shippedAmount", "发货金额").totaled("合计发货金额"),
                ReportColumn.money("receivedAmount", "回款金额").totaled("合计回款金额"),
                ReportColumn.money("returnAmount", "退货金额").totaled("合计退货金额"),
                ReportColumn.money("offsetAmount", "货款冲销").totaled("合计货款冲销"),
                ReportColumn.money("exchangeDiff", "汇兑差额").totaled("合计汇兑差额"),
                ReportColumn.money("arReductionAmount", "本期冲减应收").totaled("合计本期冲减应收"),
                ReportColumn.money("balance", "应收余额").totaled("合计应收余额"),
                // 超出铺底额可正可负（V443 起保留负数）：相加会让超限客户与未用满额度的客户互相抵销，
                // 得出一个「看着没有风险」的假数，不声明合计。
                ReportColumn.money("overFloor", "超出铺底额"),
                // 物料金额当前投影为字面量 NULL（无数据源），不声明合计。
                ReportColumn.money("materialAmount", "物料金额"));
        // 立帐取 ar_ap_ledger.amount_original_local（按 bill_date 归期）。有引用明细的收款按行拆成：
        // 实际到账、费用冲销、汇兑差额、按开账汇率冲减应收；无明细的历史/预收单保留头表事实。
        // 不能用累计 amount_settled 做期间发生额。外币下的恒等式是：
        // 期初 + 发货 + 退货 − 实际到账 − 费用冲销 + 汇兑差额 = 期末。
        NativeReadScope documentScope = COMPANY_WIDE_DOCUMENT_SCOPE;
        String core = """
                WITH posting AS (
                    SELECT client_id,
                        SUM(CASE WHEN bill_date < :from THEN amount_original_local ELSE 0 END) AS prior_posted,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to AND source_doc_type='SALES_SHIPMENT' THEN amount_original_local ELSE 0 END) AS shipped,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to AND source_doc_type='SALES_RETURN' THEN amount_original_local ELSE 0 END) AS returned,
                        SUM(CASE WHEN bill_date <= :to THEN amount_original_local ELSE 0 END) AS total_posted
                    FROM ar_ap_ledger
                    WHERE is_deleted=false
                      AND status=1
                      AND direction='AR'
                      AND open_item_kind='RECEIVABLE'
                      AND client_id IS NOT NULL
                    GROUP BY client_id
                ), receipt_line_totals AS (
                    SELECT receipt_id,
                        COUNT(*) AS line_count,
                        SUM(amount_local) AS cash_local,
                        SUM(write_off_local) AS write_off_local,
                        SUM(applied_amount_local) AS applied_local,
                        SUM(exchange_diff) AS exchange_diff
                    FROM finance_receipt_lines
                    WHERE COALESCE(is_deleted,false)=false
                    GROUP BY receipt_id
                ), receipt_fact AS (
                    SELECT receipt.client_id, receipt.bill_date,
                        CASE WHEN COALESCE(lines.line_count,0) > 0
                            THEN COALESCE(lines.cash_local,0) ELSE receipt.amount_local END AS cash_local,
                        CASE WHEN COALESCE(lines.line_count,0) > 0
                            THEN COALESCE(lines.write_off_local,0) ELSE 0 END AS write_off_local,
                        CASE WHEN COALESCE(lines.line_count,0) > 0
                            THEN COALESCE(lines.applied_local,0) ELSE receipt.amount_local END AS applied_local,
                        CASE WHEN COALESCE(lines.line_count,0) > 0
                            THEN COALESCE(lines.exchange_diff,0) ELSE 0 END AS exchange_diff
                    FROM finance_receipts receipt
                    LEFT JOIN receipt_line_totals lines ON lines.receipt_id=receipt.id
                     WHERE COALESCE(receipt.is_deleted,false)=false
                       AND receipt.status=1
                       AND receipt.receipt_kind='AR_SETTLEMENT'
                       AND receipt.client_id IS NOT NULL
                """ + " AND " + documentScope.predicate() + " " + """
                 ), prepayment_offset_fact AS (
                    SELECT batch.client_id,allocation.effective_date AS bill_date,
                           0::numeric AS cash_local,0::numeric AS write_off_local,
                           allocation.target_amount_local AS applied_local,
                           0::numeric AS exchange_diff
                    FROM customer_open_item_offsets allocation
                    JOIN customer_open_item_offset_batches batch
                      ON batch.id=allocation.offset_batch_id
                    UNION ALL
                    SELECT batch.client_id,(allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,
                           0::numeric,0::numeric,-allocation.target_amount_local,0::numeric
                    FROM customer_open_item_offsets allocation
                    JOIN customer_open_item_offset_batches batch
                      ON batch.id=allocation.offset_batch_id
                    WHERE allocation.status='REVERSED' AND allocation.reversed_at IS NOT NULL
                 ), coll AS (
                    SELECT client_id,
                        SUM(CASE WHEN bill_date < :from THEN applied_local ELSE 0 END) AS prior_applied,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to THEN cash_local ELSE 0 END) AS period_cash,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to THEN write_off_local ELSE 0 END) AS period_write_off,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to THEN exchange_diff ELSE 0 END) AS period_exchange_diff,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to THEN applied_local ELSE 0 END) AS period_applied,
                        SUM(CASE WHEN bill_date <= :to THEN applied_local ELSE 0 END) AS total_applied
                    FROM (
                        SELECT * FROM receipt_fact
                        UNION ALL
                        SELECT * FROM prepayment_offset_fact
                    ) collection_event
                    GROUP BY client_id
                )
                SELECT c.code AS "partyCode", c.name AS "partyName", c.full_name AS "partyFull",
                    COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director",
                    COALESCE(c.region,'') AS "region", COALESCE(c.place_id,'') AS "district",
                    CASE c.sales_payment_type
                        WHEN 'MONTHLY' THEN '月结'
                        WHEN 'CASH' THEN '现金'
                        WHEN 'DEPOSIT' THEN '定金'
                        ELSE '待人工分类'
                    END AS "salesPaymentType",
                    CASE c.price_style
                        WHEN 6 THEN '月结' || COALESCE(NULLIF(c.tday, 0), 30) || '天'
                        WHEN 1 THEN '现金'
                        WHEN 2 THEN '提货'
                        WHEN 3 THEN '代付'
                        WHEN 4 THEN '支票'
                        WHEN 7 THEN '垫付'
                        WHEN 8 THEN '汇款'
                        WHEN 10 THEN '代收'
                        ELSE CASE WHEN c.tday IS NOT NULL AND c.tday > 0 THEN '月结' || c.tday || '天' ELSE '' END
                    END AS "settlement",
                    COALESCE(c.credit_floor,0) AS "creditFloor",
                    (COALESCE(p.prior_posted,0) - COALESCE(co.prior_applied,0)) AS "prevBalance",
                    COALESCE(p.shipped,0) AS "shippedAmount",
                    COALESCE(co.period_cash,0) AS "receivedAmount",
                    COALESCE(p.returned,0) AS "returnAmount",
                    COALESCE(co.period_write_off,0) AS "offsetAmount",
                    COALESCE(co.period_exchange_diff,0) AS "exchangeDiff",
                    COALESCE(co.period_applied,0) AS "arReductionAmount",
                    (COALESCE(p.total_posted,0) - COALESCE(co.total_applied,0)) AS "balance",
                    (COALESCE(p.total_posted,0) - COALESCE(co.total_applied,0))
                        - COALESCE(c.credit_floor,0) AS "overFloor",
                    NULL AS "materialAmount"
                FROM clients c
                JOIN posting p ON p.client_id=c.id
                LEFT JOIN coll co ON co.client_id=c.id
                LEFT JOIN client_director_v d ON d.client_id=c.id
                LEFT JOIN employees em_sel
                  ON (em_sel.id = c.owner_employee_id
                      OR (c.owner_employee_id IS NULL
                          AND em_sel.legacy_id = CASE
                              WHEN BTRIM(COALESCE(c.emp_id,'')) ~ '^[0-9]{1,9}$'
                              THEN BTRIM(c.emp_id)::int ELSE NULL END))
                """;
        return executeRawPaged(cols, core, "c.name", keyword, from, to, page, size, "c", documentScope);
    }

    /** D 应付款汇总（按供应商；附件 3 口径，2026-07-29 重做）：
     *  供应商编号/简称/全称/结算期限/上月余额/货款金额/付款金额/退货金额/货款冲销/货款余额/应付合计。
     *  恒等式：期初+货款+退货−付款=期末（与 B 应收同「立帐−付款」时序口径）。
     *  模具款四列（模具款/付款/冲销/余额）暂无模具立帐数据源，占位 NULL（注释见 SQL）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse payableSummary(String keyword, LocalDate from, LocalDate to,
                                              Map<String, String> facets, int page, int size, String sort, String order) {
        requireCompanyWideReportAccess();
        return payableSummaryAuthorized(keyword, from, to, facets, page, size, sort, order);
    }

    private ReportTableResponse payableSummaryAuthorized(
            String keyword, LocalDate from, LocalDate to,
            Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("partyCode", "供应商编号", 110),
                ReportColumn.text("partyName", "供应商简称", 160),
                ReportColumn.text("partyFull", "供应商全称", 200),
                ReportColumn.text("settlement", "结算期限", 150),
                // 一行一供应商、全部为人民币口径的期间发生额/余额：合计行上恒等式
                // 期初+货款+退货−核销=期末 同样成立。
                ReportColumn.money("prevBalance", "期初应付").totaled("合计期初应付"),
                ReportColumn.money("goodsAmount", "采购入库").totaled("合计采购入库"),
                ReportColumn.money("subcontractAmount", "委外加工入库").totaled("合计委外加工入库"),
                ReportColumn.money("purchaseReturnAmount", "采购退货/质检贷项抵减")
                        .totaled("合计采购退货/质检贷项抵减"),
                ReportColumn.money("subcontractReturnAmount", "委外退货/质检贷项抵减")
                        .totaled("合计委外退货/质检贷项抵减"),
                ReportColumn.money("wasteDeductionAmount", "历史委外损耗扣款(兼容)")
                        .totaled("合计历史委外损耗扣款"),
                ReportColumn.money("claimOffsetAmount", "委外索赔贷项立账").totaled("合计委外索赔贷项立账"),
                ReportColumn.money("reversedAmount", "立账红冲净额").totaled("合计立账红冲净额"),
                ReportColumn.money("paidAmount", "实际付款").totaled("合计实际付款"),
                ReportColumn.money("settledAmount", "账面核销").totaled("合计账面核销"),
                ReportColumn.money("exchangeDifferenceLocal", "付款汇兑差额").totaled("合计付款汇兑差额"),
                ReportColumn.money("offsetAmount", "应付被抵销").totaled("合计应付被抵销"),
                ReportColumn.money("creditReleasedAmount", "贷项已使用").totaled("合计贷项已使用"),
                ReportColumn.money("balance", "期末应付").totaled("合计期末应付"),
                // 应付合计与期末应付是同一个 SQL 表达式的重复列，再出一项合计只会把同一个数显示两遍。
                ReportColumn.money("totalBalance", "应付合计"));
        // 立账、付款、往来抵销及各自反向均展开为带日期事件，再截断到 :to。
        // 本期实际付款（现金）、账面核销与汇兑差额分列；未付恒等式只减账面核销，不直接减现金。
        NativeReadScope documentScope = COMPANY_WIDE_DOCUMENT_SCOPE;
        String core = """
                WITH ledger_events AS (
                    SELECT ledger.supplier_id, ledger.bill_date AS event_date,
                           ledger.amount_original_local AS amount_local,
                           ledger.source_doc_type, 'POST' AS event_type
                    FROM ar_ap_ledger ledger
                    WHERE ledger.direction='AP' AND ledger.supplier_id IS NOT NULL
                      AND ledger.bill_date <= :to
                      AND (
                          (ledger.status=1 AND ledger.is_deleted=false)
                          OR (ledger.status=-1 AND ledger.is_deleted=true
                              AND ledger.deleted_at IS NOT NULL)
                      )
                    UNION ALL
                    SELECT ledger.supplier_id, (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date,
                           -ledger.amount_original_local,
                           ledger.source_doc_type, 'REVERSE' AS event_type
                    FROM ar_ap_ledger ledger
                    WHERE ledger.direction='AP' AND ledger.supplier_id IS NOT NULL
                      AND ledger.status=-1 AND ledger.is_deleted=true
                      AND ledger.deleted_at IS NOT NULL
                      AND (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date <= :to
                ), posting AS (
                    SELECT supplier_id,
                        SUM(CASE WHEN event_date < :from THEN amount_local ELSE 0 END) AS prior_posted,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST' AND source_doc_type='PURCHASE_RECEIPT' THEN amount_local ELSE 0 END) AS purchase_receipt,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST' AND source_doc_type='SUBCONTRACT_RECEIPT' THEN amount_local ELSE 0 END) AS subcontract_receipt,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST'
                            AND source_doc_type IN('PURCHASE_RETURN','PURCHASE_IQC_CREDIT')
                            THEN amount_local ELSE 0 END) AS purchase_return,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST'
                            AND source_doc_type IN('SUBCONTRACT_RETURN','SUBCONTRACT_IQC_CREDIT')
                            THEN amount_local ELSE 0 END) AS subcontract_return,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST' AND source_doc_type='SUBCONTRACT_WASTE' THEN amount_local ELSE 0 END) AS waste_deduction,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='POST' AND source_doc_type='SUBCONTRACT_LOSS_OFFSET' THEN amount_local ELSE 0 END) AS claim_offset,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to AND event_type='REVERSE' THEN amount_local ELSE 0 END) AS reversed_amount,
                        SUM(CASE WHEN event_date <= :to THEN amount_local ELSE 0 END) AS posted_to
                    FROM ledger_events
                    GROUP BY supplier_id
                ), payment_facts AS (
                    SELECT payment.supplier_id, payment.bill_date,
                           payment.status,
                           (COALESCE(payment.reversed_at, payment.updated_at)
                               AT TIME ZONE 'Asia/Shanghai')::date AS reverse_date,
                           CASE WHEN COALESCE(line_total.line_count,0)>0
                               THEN line_total.cash_local ELSE payment.amount_local END AS cash_local,
                           CASE WHEN COALESCE(line_total.line_count,0)>0
                               THEN line_total.book_local ELSE payment.amount_local END AS book_local
                    FROM finance_payments payment
                    LEFT JOIN LATERAL (
                        SELECT COUNT(*) AS line_count,
                               COALESCE(SUM(line.amount_local),0) AS cash_local,
                               COALESCE(SUM(COALESCE(
                                   line.applied_amount_local,
                                   line.amount_local-COALESCE(line.exchange_diff,0))),0) AS book_local
                        FROM finance_payment_lines line
                        WHERE line.payment_id=payment.id
                          AND COALESCE(line.is_deleted,false)=false
                    ) line_total ON TRUE
                    WHERE COALESCE(payment.is_deleted,false)=false
                      AND payment.status IN (1,-1)
                      AND payment.supplier_id IS NOT NULL
                      AND payment.bill_date <= :to
                """ + " AND " + documentScope.predicate() + " " + """
                ), payment_events AS (
                    SELECT supplier_id, bill_date AS event_date,
                           cash_local, book_local, 'PAYMENT' AS event_type
                    FROM payment_facts
                    UNION ALL
                    SELECT supplier_id, reverse_date,
                           -cash_local, -book_local, 'PAYMENT_REVERSE' AS event_type
                    FROM payment_facts
                    WHERE status=-1 AND reverse_date IS NOT NULL AND reverse_date <= :to
                ), paid AS (
                    SELECT supplier_id,
                        SUM(CASE WHEN event_date < :from THEN cash_local ELSE 0 END) AS prior_cash,
                        SUM(CASE WHEN event_date < :from THEN book_local ELSE 0 END) AS prior_book,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to THEN cash_local ELSE 0 END) AS period_cash,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to THEN book_local ELSE 0 END) AS period_book,
                        SUM(CASE WHEN event_date <= :to THEN book_local ELSE 0 END) AS book_to
                    FROM payment_events
                    GROUP BY supplier_id
                ), offset_events AS (
                    SELECT offset_row.supplier_id, offset_row.effective_date AS event_date,
                           offset_row.target_amount_local AS target_local,
                           offset_row.source_amount_local AS source_local,
                           'OFFSET' AS event_type
                    FROM supplier_open_item_offsets offset_row
                    WHERE offset_row.effective_date <= :to
                      AND offset_row.status IN ('APPLIED','REVERSED')
                    UNION ALL
                    SELECT offset_row.supplier_id, (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,
                           -offset_row.target_amount_local,
                           -offset_row.source_amount_local,
                           'OFFSET_REVERSE' AS event_type
                    FROM supplier_open_item_offsets offset_row
                    WHERE offset_row.status='REVERSED'
                      AND offset_row.reversed_at IS NOT NULL
                      AND (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date <= :to
                ), offsets AS (
                    SELECT supplier_id,
                        SUM(CASE WHEN event_date < :from THEN target_local ELSE 0 END) AS prior_target,
                        SUM(CASE WHEN event_date < :from THEN source_local ELSE 0 END) AS prior_source,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to THEN target_local ELSE 0 END) AS period_target,
                        SUM(CASE WHEN event_date BETWEEN :from AND :to THEN source_local ELSE 0 END) AS period_source,
                        SUM(CASE WHEN event_date <= :to THEN target_local ELSE 0 END) AS target_to,
                        SUM(CASE WHEN event_date <= :to THEN source_local ELSE 0 END) AS source_to
                    FROM offset_events
                    GROUP BY supplier_id
                )
                SELECT s.code AS "partyCode", s.name AS "partyName", COALESCE(s.description, s.name) AS "partyFull",
                    CASE s.price_style
                        WHEN 6 THEN '月结' || COALESCE(NULLIF(s.tday, 0), 30) || '天'
                        WHEN 1 THEN '现金'
                        WHEN 2 THEN '提货'
                        WHEN 3 THEN '代付'
                        WHEN 4 THEN '支票'
                        WHEN 7 THEN '垫付'
                        WHEN 8 THEN '汇款'
                        WHEN 10 THEN '代收'
                        ELSE CASE WHEN s.tday IS NOT NULL AND s.tday > 0 THEN '账期' || s.tday || '天' ELSE '' END
                    END AS "settlement",
                    (COALESCE(p.prior_posted,0) - COALESCE(pa.prior_book,0)
                        + COALESCE(o.prior_source,0) - COALESCE(o.prior_target,0)) AS "prevBalance",
                    COALESCE(p.purchase_receipt,0) AS "goodsAmount",
                    COALESCE(p.subcontract_receipt,0) AS "subcontractAmount",
                    COALESCE(p.purchase_return,0) AS "purchaseReturnAmount",
                    COALESCE(p.subcontract_return,0) AS "subcontractReturnAmount",
                    COALESCE(p.waste_deduction,0) AS "wasteDeductionAmount",
                    COALESCE(p.claim_offset,0) AS "claimOffsetAmount",
                    COALESCE(p.reversed_amount,0) AS "reversedAmount",
                    COALESCE(pa.period_cash,0) AS "paidAmount",
                    COALESCE(pa.period_book,0) AS "settledAmount",
                    (COALESCE(pa.period_cash,0) - COALESCE(pa.period_book,0)) AS "exchangeDifferenceLocal",
                    COALESCE(o.period_target,0) AS "offsetAmount",
                    COALESCE(o.period_source,0) AS "creditReleasedAmount",
                    (COALESCE(p.posted_to,0) - COALESCE(pa.book_to,0)
                        + COALESCE(o.source_to,0) - COALESCE(o.target_to,0)) AS "balance",
                    (COALESCE(p.posted_to,0) - COALESCE(pa.book_to,0)
                        + COALESCE(o.source_to,0) - COALESCE(o.target_to,0)) AS "totalBalance"
                FROM suppliers s
                JOIN posting p ON p.supplier_id=s.id
                LEFT JOIN paid pa ON pa.supplier_id=s.id
                LEFT JOIN offsets o ON o.supplier_id=s.id
                """;
        return executeRawPaged(cols, core, "s.name", keyword, from, to, page, size, "s", documentScope);
    }

    /** 原生 SQL 分页执行器（CTE/聚合报表用，如 B 应收汇总 / D 应付汇总）。SQL 含 :from/:to[/:kw] 参数。
     *  [partyAlias] 外层主表别名（应收=客户 c / 应付=供应商 s），keyword 走 {alias}.name/{alias}.code。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeRawPaged(List<ReportColumn> cols, String coreSql, String orderBy,
                                                 String keyword, LocalDate from, LocalDate to, int page, int size,
                                                 String partyAlias, NativeReadScope documentScope) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        String where = "WHERE TRUE";
        if (keyword != null && !keyword.isBlank()) {
            where = "WHERE (LOWER(COALESCE(" + partyAlias + ".name,'')) LIKE LOWER(:kw) OR LOWER(COALESCE(" + partyAlias + ".code,'')) LIKE LOWER(:kw))";
        }
        var dq = em.createNativeQuery(coreSql + " " + where + " ORDER BY " + orderBy + " LIMIT :__l OFFSET :__o");
        bindRaw(dq, keyword, from, to);
        documentScope.bind(dq);
        dq.setParameter("__l", safeSize);
        dq.setParameter("__o", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dq.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < cols.size(); i++) m.put(cols.get(i).key(), norm(r[i]));
            items.add(m);
        }
        var cq = em.createNativeQuery("SELECT COUNT(*) FROM (" + coreSql + " " + where + ") zz");
        bindRaw(cq, keyword, from, to);
        documentScope.bind(cq);
        long total = ((Number) cq.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        // 合计：把整段 CTE 原样包成派生表再聚合（Postgres 允许子查询里带 WITH），
        // 用的是同一份 where 与同一套绑定（:from/:to/:kw + 对象级授权谓词），覆盖整个结果集。
        List<com.uten.imp.common.report.ReportTotal> totals = com.uten.imp.common.report.ReportTotalsCalculator.compute(
                em, coreSql, "", where,
                q -> { bindRaw(q, keyword, from, to); documentScope.bind(q); },
                reportTotalSpecs(cols, cols));
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages, totals);
    }

    private static void bindRaw(jakarta.persistence.Query q, String keyword, LocalDate from, LocalDate to) {
        if (keyword != null && !keyword.isBlank()) q.setParameter("kw", "%" + keyword.toLowerCase() + "%");
        q.setParameter("from", from);
        q.setParameter("to", to);
    }

    // ======================== ② 收付款明细/汇总 E·F / G·H ========================

    /** E 销售收款明细：一行对应一次应收引用；无引用的历史预收保留一行头表事实。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receiptDetail(String billNo, UUID clientId, UUID accountId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        return receiptDetailAuthorized(billNo, clientId, accountId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse receiptDetailAuthorized(
            String billNo, UUID clientId, UUID accountId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order,
            OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户名称", 160), ReportColumn.text("clientFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100), ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("district", "所属地区", 110),
                ReportColumn.text("accountName", "收款账户", 130),
                ReportColumn.text("arBillNo", "应收单号", 150),
                ReportColumn.text("salesOrderNos", "销售订单号", 190),
                ReportColumn.text("currencyCode", "币别", 80),
                // 汇率是比率，不声明合计。
                ReportColumn.number("receiptRate", "收款汇率"),
                // 应收款金额取自被引用的立账台账头（ledger.amount_original）：同一张立账被多次收款、
                // 或一次收款引用多行时会在多行上重复出现，相加即重复计数，不声明合计。
                ReportColumn.money("receivableOriginal", "应收款金额"),
                // 收款前/后未收是时点快照，把快照相加没有任何账务含义，不声明合计。
                ReportColumn.money("balanceBeforeOriginal", "收款前未收"),
                // 以下为本行自身的发生额：原币按币别分组，人民币列不分组。
                ReportColumn.money("amountOriginal", "本次收款").totaled("合计本次收款", "currencyCode"),
                ReportColumn.money("amountLocal", "本次收款人民币").totaled("合计本次收款人民币"),
                ReportColumn.money("writeOffOriginal", "本次冲销").totaled("合计本次冲销", "currencyCode"),
                ReportColumn.money("writeOffLocal", "冲销费用人民币").totaled("合计冲销费用人民币"),
                ReportColumn.money("appliedLocal", "本次冲减应收").totaled("合计本次冲减应收"),
                ReportColumn.money("exchangeDiff", "汇兑差额").totaled("合计汇兑差额"),
                ReportColumn.money("balanceAfterOriginal", "本次后未收"),
                // 手续费/其它费用在单头，投影处已用 ROW_NUMBER() 只挂到每张收款单的首行（其余行给 0），
                // 所以整集求和恰好等于「每张单计一次」——是可加的，且为人民币口径（见 FinanceReceiptService
                // 把 bank_fee+other_fee 直接写入对账 amount_local）。
                ReportColumn.money("bankFee", "手续费").totaled("合计手续费"),
                ReportColumn.money("otherFee", "其它费用").totaled("合计其它费用"),
                ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳收款单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director", COALESCE(c.region,'') AS "region",
                       COALESCE(c.place_id,'') AS "district", a.name AS "accountName",
                       COALESCE(i.applied_bill_no, ledger.bill_no) AS "arBillNo",
                       orders.sales_order_nos AS "salesOrderNos", currency.code AS "currencyCode",
                       COALESCE(i.exchange_rate, t.exchange_rate) AS "receiptRate",
                       ledger.amount_original AS "receivableOriginal",
                       i.balance_before_original AS "balanceBeforeOriginal",
                       COALESCE(i.amount_original, t.amount_original) AS "amountOriginal",
                       COALESCE(i.amount_local, t.amount_local) AS "amountLocal",
                       COALESCE(i.write_off_amount,0) AS "writeOffOriginal",
                       COALESCE(i.write_off_local,0) AS "writeOffLocal",
                       COALESCE(i.applied_amount_local, t.amount_local) AS "appliedLocal",
                       COALESCE(i.exchange_diff,0) AS "exchangeDiff",
                       i.balance_after_original AS "balanceAfterOriginal",
                       CASE WHEN ROW_NUMBER() OVER (PARTITION BY t.id ORDER BY i.line_no NULLS FIRST, i.id) = 1
                            THEN t.bank_fee ELSE 0 END AS "bankFee",
                       CASE WHEN ROW_NUMBER() OVER (PARTITION BY t.id ORDER BY i.line_no NULLS FIRST, i.id) = 1
                            THEN t.other_fee ELSE 0 END AS "otherFee",
                       COALESCE(i.remark, t.remark) AS "remark",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_receipts t
                LEFT JOIN finance_receipt_lines i
                  ON i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false
                LEFT JOIN clients c ON c.id=t.client_id
                LEFT JOIN client_director_v d ON d.client_id=t.client_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN employees em_sel
                  ON (em_sel.id = c.owner_employee_id
                      OR (c.owner_employee_id IS NULL
                          AND em_sel.legacy_id = CASE
                              WHEN BTRIM(COALESCE(c.emp_id,'')) ~ '^[0-9]{1,9}$'
                              THEN BTRIM(c.emp_id)::int ELSE NULL END))
                LEFT JOIN ar_ap_ledger ledger ON ledger.id=i.applied_ledger_id
                LEFT JOIN currencies currency ON currency.id=COALESCE(i.currency_id,t.currency_id)
                LEFT JOIN LATERAL (
                    SELECT string_agg(ref.source_no, ', ' ORDER BY ref.source_no) AS sales_order_nos
                    FROM ar_ap_source_refs ref
                    WHERE ref.ledger_id=i.applied_ledger_id
                ) orders ON TRUE
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false", "t.maker_id", readScope);
        addFinanceDocFilters(w, billNo, clientId, accountId, status, dateFrom, dateTo, keyword,
                "t.client_id", "t.bill_no", "t.bill_date",
                "CONCAT_WS(' ',c.name,i.applied_bill_no,orders.sales_order_nos)");
        return execute(cols, dataSelect, fromJoin, w,
                "t.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    /** F 销售收款汇总（按客户 + 币别；原币金额禁止跨币种直接相加）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receiptSummary(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size, String sort, String order) {
        return receiptSummaryAuthorized(billNo, clientId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse receiptSummaryAuthorized(
            String billNo, UUID clientId, Short status, LocalDate dateFrom,
            LocalDate dateTo, String keyword, Map<String, String> facets,
            int page, int size, String sort, String order, OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientCode", "客户编号", 110), ReportColumn.text("clientName", "客户名称", 160),
                ReportColumn.text("clientFull", "客户全称", 200), ReportColumn.text("address", "客户地址", 200),
                ReportColumn.text("district", "所属地区", 110), ReportColumn.text("currencyCode", "币别", 80),
                // 本表已按 客户×币别 分组：每行是一组的小计，跨组相加即全量合计。
                ReportColumn.number("receiptCount", "收款单数").totaled("合计收款单数"),
                ReportColumn.money("amountTotal", "实际到账原币").totaled("合计实际到账原币", "currencyCode"),
                ReportColumn.money("amountLocal", "实际到账人民币").totaled("合计实际到账人民币"),
                ReportColumn.money("writeOffLocal", "费用冲销人民币").totaled("合计费用冲销人民币"),
                ReportColumn.money("appliedLocal", "冲减应收人民币").totaled("合计冲减应收人民币"),
                ReportColumn.money("exchangeDiff", "汇兑差额").totaled("合计汇兑差额"),
                ReportColumn.money("bankFee", "手续费").totaled("合计手续费"),
                ReportColumn.money("otherFee", "其它费用").totaled("合计其它费用"));
        String dataSelect = """
                SELECT c.code AS "clientCode", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(c.address,'') AS "address", COALESCE(c.place_id,'') AS "district",
                       currency.code AS "currencyCode", COUNT(*) AS "receiptCount",
                       SUM(t.amount_original) AS "amountTotal",
                       SUM(CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN COALESCE(lines.cash_local,0) ELSE t.amount_local END) AS "amountLocal",
                       SUM(CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN COALESCE(lines.write_off_local,0) ELSE 0 END) AS "writeOffLocal",
                       SUM(CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN COALESCE(lines.applied_local,0) ELSE t.amount_local END) AS "appliedLocal",
                       SUM(CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN COALESCE(lines.exchange_diff,0) ELSE 0 END) AS "exchangeDiff",
                       SUM(t.bank_fee) AS "bankFee", SUM(t.other_fee) AS "otherFee"
                """;
        String fromJoin = """
                FROM finance_receipts t
                JOIN clients c ON c.id=t.client_id
                LEFT JOIN currencies currency ON currency.id=t.currency_id
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) AS line_count,
                           SUM(i.amount_local) AS cash_local,
                           SUM(i.write_off_local) AS write_off_local,
                           SUM(i.applied_amount_local) AS applied_local,
                           SUM(i.exchange_diff) AS exchange_diff
                    FROM finance_receipt_lines i
                    WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false
                ) lines ON TRUE
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false", "t.maker_id", readScope);
        addFinanceDocFilters(w, billNo, clientId, null, status, dateFrom, dateTo, keyword,
                "t.client_id", "t.bill_no", "t.bill_date", "c.name");
        return executeGrouped(cols, dataSelect, fromJoin, w, "c.name,currency.code",
                "c.id,c.code,c.name,c.full_name,c.address,c.place_id,currency.id,currency.code", page, size);
    }

    /** G 采购付款明细（finance_payments + suppliers + accounts + 人员）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse paymentDetail(String billNo, UUID supplierId, UUID accountId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        return paymentDetailAuthorized(billNo, supplierId, accountId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse paymentDetailAuthorized(
            String billNo, UUID supplierId, UUID accountId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order,
            OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 180), ReportColumn.text("operatorName", "付款人", 100),
                ReportColumn.text("accountName", "付款帐户", 130),
                // 一行一付款单：实付原币按币别分组（本表不展示币别列，靠隐藏列 __currencyCode 分组），
                // 实付人民币不分组。付款总额与实付金额(外)是同一个 SQL 表达式的重复列，只出一项合计。
                ReportColumn.money("amountOriginal", "实付金额(外)").totaled("合计实付金额(外)", "__currencyCode"),
                ReportColumn.money("amountTotal", "付款总额"),
                ReportColumn.money("amountLocal", "实付金额").totaled("合计实付金额"),
                ReportColumn.text("incomeItem", "收入项目名称", 130), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("handlerName", "经手人", 100), ReportColumn.text("remark", "备注", 160),
                // 隐藏分组列：本报表不展示币别，但原币合计必须按币别分组（绝不跨币种相加），
                // 故把币别码投进派生表、不进前端 columns（"__" 前缀由 execute 过滤）。
                ReportColumn.text("__currencyCode", ""),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳付款单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", s.name AS "supplierName",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", t.amount_original AS "amountOriginal", t.amount_original AS "amountTotal",
                       t.amount_local AS "amountLocal", NULL AS "incomeItem", ca.name AS "counterpartAccount",
                       COALESCE(em_op.full_name, t.operator_name, '') AS "handlerName", t.remark AS "remark",
                       cur.code AS "__currencyCode", t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_payments t
                LEFT JOIN suppliers s ON s.id=t.supplier_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=t.counterpart_account_id
                LEFT JOIN currencies cur ON cur.id=t.currency_id
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false", "t.maker_id", readScope);
        addFinanceDocFilters(w, billNo, supplierId, accountId, status, dateFrom, dateTo, keyword,
                "t.supplier_id", "t.bill_no", "t.bill_date", "s.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size, sort, order);
    }

    /** H 采购付款汇总（一行一付款单 + 关联 AP 立帐单/已付/未付/本次付款/本次余额）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse paymentSummary(String billNo, UUID supplierId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size, String sort, String order) {
        return paymentSummaryAuthorized(billNo, supplierId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse paymentSummaryAuthorized(
            String billNo, UUID supplierId, Short status, LocalDate dateFrom,
            LocalDate dateTo, String keyword, Map<String, String> facets,
            int page, int size, String sort, String order, OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 180), ReportColumn.text("operatorName", "付款人", 100),
                ReportColumn.text("payStyle", "付款方式", 100), ReportColumn.text("currencyCode", "币别", 80),
                // 汇率是比率，不声明合计。
                ReportColumn.number("rate", "汇率"),
                ReportColumn.money("amountTotal", "付款总额").totaled("合计付款总额", "currencyCode"),
                ReportColumn.money("amountLocal", "实付金额").totaled("合计实付金额"),
                ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100), ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("ledgerBillNo", "立帐单号", 150), ReportColumn.date("tradeDate", "交易日期"),
                // 已付/未付/本次余额取自关联立账台账的累计快照（amount_settled / amount_balance）：
                // 是「截至目前」的状态而非本单发生额，跨单相加会把同一张立账的累计数重复计入，不声明合计。
                ReportColumn.money("paid", "已付金额"), ReportColumn.money("unpaid", "未付金额"),
                // 本次付款与实付金额是同一个 SQL 表达式的重复列，只在实付金额上出一项合计。
                ReportColumn.money("thisPay", "本次付款"), ReportColumn.money("thisBalance", "本次余额"),
                ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("counterpartAccount", "对方账户", 140), ReportColumn.text("handlerName", "经手人", 100),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳付款单编辑页
        // 关联 ar_ap_ledger(DIRECT_PAYMENT)：直接付款 1:1 建一条 AP 立帐行（source_doc_id=付款单 id），
        // 取 立帐单号/已付(amount_settled)/未付(amount_balance)。迁移期 source_doc_id 已回填（~69% 命中），未命中则空。
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", s.name AS "supplierName",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       CAST(t.payment_method_legacy_id AS text) AS "payStyle", cur.code AS "currencyCode", t.exchange_rate AS "rate",
                       t.amount_original AS "amountTotal", t.amount_local AS "amountLocal",
                       COALESCE(em_mk.full_name, t.maker_name,'') AS "makerName",
                       COALESCE(em_ap.full_name, t.approver_name,'') AS "approverName", t.remark AS "remark",
                       ap.bill_no AS "ledgerBillNo", ap.bill_date AS "tradeDate",
                       ap.amount_settled AS "paid", ap.amount_balance AS "unpaid",
                       t.amount_local AS "thisPay", ap.amount_balance AS "thisBalance", COALESCE(ap.remark,'') AS "summary",
                       ca.name AS "counterpartAccount",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "handlerName",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_payments t
                LEFT JOIN suppliers s ON s.id=t.supplier_id
                LEFT JOIN currencies cur ON cur.id=t.currency_id
                LEFT JOIN accounts ca ON ca.id=t.counterpart_account_id
                LEFT JOIN ar_ap_ledger ap ON ap.source_doc_id=t.id AND ap.source_doc_type='DIRECT_PAYMENT' AND ap.is_deleted=false
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id=t.maker_id
                    OR (t.maker_id IS NULL AND em_mk.legacy_id=t.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id=t.approver_id
                    OR (t.approver_id IS NULL AND em_ap.legacy_id=t.approver_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false", "t.maker_id", readScope);
        addFinanceDocFilters(w, billNo, supplierId, null, status, dateFrom, dateTo, keyword,
                "t.supplier_id", "t.bill_no", "t.bill_date", "s.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size, sort, order);
    }

    // ======================== ③ 费用/收入明细/汇总 M·N / O·P + V ========================

    /** M 一般费用明细（finance_expense_items JOIN finance_expenses，按费用项目/部门分摊）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse expenseDetail(String billNo, UUID accountId, UUID departmentId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        return expenseDetailAuthorized(billNo, accountId, departmentId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse expenseDetailAuthorized(
            String billNo, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order,
            OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "付款人", 100), ReportColumn.text("accountName", "付款帐户", 130),
                ReportColumn.text("currencyCode", "币别", 80),
                // 付款总额/实付金额是费用单<b>单头</b>金额，一张单有几条费用明细就在几行上重复出现，
                // 相加即重复计数（这正是合计最容易骗人的地方），不声明合计。
                ReportColumn.money("amountTotal", "付款总额"),
                ReportColumn.money("amountLocal", "实付金额"), ReportColumn.text("styleName", "费用项目名称", 130),
                // 费用行数量没有随行的单位列（费用项目单位五花八门），跨行相加会拼出一个无量纲的数；
                // 单价相加更没有意义。两列都不声明合计。
                ReportColumn.number("qty", "数量"), ReportColumn.money("price", "单价"),
                // 支出金额是本行自身的人民币金额，可加。
                ReportColumn.money("lineAmount", "支出金额").totaled("合计支出金额"),
                ReportColumn.text("counterpartName", "对方", 120),
                ReportColumn.text("departmentName", "部门", 120), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("remark", "备注", 160), ReportColumn.text("summary", "摘要", 160),
                // 序号是行号，不是量。
                ReportColumn.number("lineNo", "序号"),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳费用单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", cur.code AS "currencyCode", t.amount_original AS "amountTotal", t.amount_local AS "amountLocal",
                       ps.name AS "styleName", i.qty AS "qty", i.price AS "price", i.amount_local AS "lineAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", d.name AS "departmentName",
                       ca.name AS "counterpartAccount", t.remark AS "remark", i.summary AS "summary", i.line_no AS "lineNo",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_expense_items i
                JOIN finance_expenses t ON t.id=i.expense_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN currencies cur ON cur.id=t.currency_id
                LEFT JOIN payment_styles ps ON ps.id=i.expense_style_id
                LEFT JOIN departments d ON d.id=i.department_id
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false",
                "t.maker_id", readScope);
        addFinanceItemFilters(w, billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    /** N 一般费用汇总（按 单号×部门×费用项目 GROUP BY items）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse expenseSummary(String billNo, UUID departmentId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size, String sort, String order) {
        return expenseSummaryAuthorized(billNo, departmentId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse expenseSummaryAuthorized(
            String billNo, UUID departmentId, Short status, LocalDate dateFrom,
            LocalDate dateTo, String keyword, Map<String, String> facets,
            int page, int size, String sort, String order, OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "付款人", 100), ReportColumn.text("accountName", "付款帐户", 130),
                // 实付金额是费用单单头金额，按费用项目展开后在多行重复，不声明合计（同 M 明细）。
                ReportColumn.money("amountLocal", "实付金额"), ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100), ReportColumn.text("remark", "备注", 160),
                // 数量无随行单位列、单价是比率，均不声明合计。
                ReportColumn.text("styleName", "费用项目名称", 130), ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"),
                ReportColumn.money("lineAmount", "支出金额").totaled("合计支出金额"),
                ReportColumn.text("counterpartName", "对方", 120), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳费用单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName", a.name AS "accountName",
                       t.amount_local AS "amountLocal", COALESCE(em_mk.full_name, t.maker_name,'') AS "makerName",
                       COALESCE(em_ap.full_name, t.approver_name,'') AS "approverName", t.remark AS "remark",
                       ps.name AS "styleName", i.qty AS "qty", i.price AS "price", i.amount_local AS "lineAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount", i.summary AS "summary",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_expense_items i
                JOIN finance_expenses t ON t.id=i.expense_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.expense_style_id
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id=t.maker_id
                    OR (t.maker_id IS NULL AND em_mk.legacy_id=t.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id=t.approver_id
                    OR (t.approver_id IS NULL AND em_ap.legacy_id=t.approver_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false",
                "t.maker_id", readScope);
        addFinanceItemFilters(w, billNo, null, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    /** O 其它收入明细。 */
    @Transactional(readOnly = true)
    public ReportTableResponse incomeDetail(String billNo, UUID accountId, UUID departmentId, Short status,
                                            LocalDate dateFrom, LocalDate dateTo, String keyword,
                                            Map<String, String> facets, int page, int size, String sort, String order) {
        return incomeDetailAuthorized(billNo, accountId, departmentId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse incomeDetailAuthorized(
            String billNo, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order,
            OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "收款人", 100), ReportColumn.text("accountName", "收款帐户", 130),
                // 收款总额是收入单<b>单头</b>金额，一张单有几条收入明细就在几行上重复出现，相加即重复计数；
                // 本明细表没有投影行级金额列，所以整张表没有可加的列，不出合计条。
                ReportColumn.money("amountTotal", "收款总额"), ReportColumn.text("styleName", "收入项目名称", 130),
                ReportColumn.text("counterpartName", "对方", 120), ReportColumn.text("counterpartAccount", "对方账号", 140),
                ReportColumn.text("summary", "摘要", 160), ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳收入单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", t.amount_original AS "amountTotal", ps.name AS "styleName",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount",
                       i.summary AS "summary", t.remark AS "remark",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_other_income_items i
                JOIN finance_other_incomes t ON t.id=i.income_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.income_style_id
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false",
                "t.maker_id", readScope);
        addFinanceItemFilters(w, billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    /** P 其它收入汇总。 */
    @Transactional(readOnly = true)
    public ReportTableResponse incomeSummary(String billNo, UUID departmentId, Short status, LocalDate dateFrom,
                                             LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size, String sort, String order) {
        return incomeSummaryAuthorized(billNo, departmentId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse incomeSummaryAuthorized(
            String billNo, UUID departmentId, Short status, LocalDate dateFrom,
            LocalDate dateTo, String keyword, Map<String, String> facets,
            int page, int size, String sort, String order, OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "收款人", 100), ReportColumn.text("accountName", "收款帐户", 130),
                // 收款总额/实付金额是单头金额，按收入项目展开后在多行重复，不声明合计。
                ReportColumn.money("amountTotal", "收款总额"), ReportColumn.money("amountLocal", "实付金额"),
                ReportColumn.text("makerName", "制单员", 100), ReportColumn.text("approverName", "审核员", 100),
                ReportColumn.text("remark", "备注", 160), ReportColumn.text("styleName", "收入项目名称", 130),
                // 收入金额是本行自身的人民币金额，可加。
                ReportColumn.money("incomeAmount", "收入金额").totaled("合计收入金额"),
                ReportColumn.text("counterpartName", "对方", 120),
                ReportColumn.text("counterpartAccount", "对方账户", 140), ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳收入单编辑页
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName", a.name AS "accountName",
                       t.amount_original AS "amountTotal", t.amount_local AS "amountLocal",
                       COALESCE(em_mk.full_name, t.maker_name,'') AS "makerName",
                       COALESCE(em_ap.full_name, t.approver_name,'') AS "approverName", t.remark AS "remark",
                       ps.name AS "styleName", i.amount_local AS "incomeAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount", i.summary AS "summary",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_other_income_items i
                JOIN finance_other_incomes t ON t.id=i.income_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.income_style_id
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id=t.maker_id
                    OR (t.maker_id IS NULL AND em_mk.legacy_id=t.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id=t.approver_id
                    OR (t.approver_id IS NULL AND em_ap.legacy_id=t.approver_legacy_id)
                """;
        WhereBuilder w = financeDocumentWhere(
                "WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false",
                "t.maker_id", readScope);
        addFinanceItemFilters(w, billNo, null, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    /** V 费用冲销明细：费用是应收冲减而非账户现金，按收款引用行展示。 */
    @Transactional(readOnly = true)
    public ReportTableResponse feeOffsetDetail(String billNo, UUID clientId, UUID accountId, Short status,
                                               LocalDate dateFrom, LocalDate dateTo, String keyword,
                                               Map<String, String> facets, int page, int size, String sort, String order) {
        return feeOffsetDetailAuthorized(billNo, clientId, accountId, status, dateFrom, dateTo,
                keyword, facets, page, size, sort, order, access.scope());
    }

    private ReportTableResponse feeOffsetDetailAuthorized(
            String billNo, UUID clientId, UUID accountId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String keyword,
            Map<String, String> facets, int page, int size, String sort, String order,
            OwnerScope readScope) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户名称", 160), ReportColumn.text("clientFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100), ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("district", "所属地区", 110),
                ReportColumn.text("operatorName", "收款人", 100),
                ReportColumn.text("arBillNo", "应收单号", 150),
                ReportColumn.text("salesOrderNos", "销售订单号", 190),
                ReportColumn.text("currencyCode", "币别", 80),
                // 冲销前/后未收是时点快照，相加没有账务含义，不声明合计。
                ReportColumn.money("balanceBeforeOriginal", "冲销前未收"),
                // 以下为本行自身发生额：原币按币别分组，人民币列不分组。
                ReportColumn.money("thisReceiptOriginal", "本次收款").totaled("合计本次收款", "currencyCode"),
                ReportColumn.money("thisReceiptLocal", "本次收款人民币").totaled("合计本次收款人民币"),
                ReportColumn.money("writeOffOriginal", "本次冲销").totaled("合计本次冲销", "currencyCode"),
                ReportColumn.money("writeOffLocal", "冲销费用人民币").totaled("合计冲销费用人民币"),
                ReportColumn.money("appliedLocal", "本次冲减应收").totaled("合计本次冲减应收"),
                ReportColumn.money("balanceAfterOriginal", "冲销后未收"),
                // 单头手续费用 ROW_NUMBER() 只挂到每张收款单的首行，整集求和恰好每单计一次（人民币口径）。
                ReportColumn.money("bankFee", "手续费").totaled("合计手续费"),
                ReportColumn.money("otherFee", "其它费用").totaled("合计其它费用"),
                ReportColumn.text("otherFeeStyle", "其它费用项目", 150),
                ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳收款单编辑页（费用冲销源单为收款单）
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director", COALESCE(c.region,'') AS "region",
                       COALESCE(c.place_id,'') AS "district",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName",
                       COALESCE(i.applied_bill_no, ledger.bill_no) AS "arBillNo",
                       orders.sales_order_nos AS "salesOrderNos", currency.code AS "currencyCode",
                       i.balance_before_original AS "balanceBeforeOriginal",
                       COALESCE(i.amount_original,t.amount_original) AS "thisReceiptOriginal",
                       COALESCE(i.amount_local,t.amount_local) AS "thisReceiptLocal",
                       COALESCE(i.write_off_amount,0) AS "writeOffOriginal",
                       COALESCE(i.write_off_local,0) AS "writeOffLocal",
                       COALESCE(i.applied_amount_local,t.amount_local) AS "appliedLocal",
                       i.balance_after_original AS "balanceAfterOriginal",
                       CASE WHEN ROW_NUMBER() OVER (PARTITION BY t.id ORDER BY i.line_no NULLS FIRST, i.id) = 1
                            THEN t.bank_fee ELSE 0 END AS "bankFee",
                       CASE WHEN ROW_NUMBER() OVER (PARTITION BY t.id ORDER BY i.line_no NULLS FIRST, i.id) = 1
                            THEN t.other_fee ELSE 0 END AS "otherFee",
                       style.name AS "otherFeeStyle", COALESCE(i.remark,t.remark) AS "remark",
                       t.id AS "__srcId"
                """;
        String fromJoin = """
                FROM finance_receipts t
                LEFT JOIN finance_receipt_lines i
                  ON i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false
                LEFT JOIN clients c ON c.id=t.client_id
                LEFT JOIN client_director_v d ON d.client_id=t.client_id
                LEFT JOIN employees em_sel
                  ON (em_sel.id = c.owner_employee_id
                      OR (c.owner_employee_id IS NULL
                          AND em_sel.legacy_id = CASE
                              WHEN BTRIM(COALESCE(c.emp_id,'')) ~ '^[0-9]{1,9}$'
                              THEN BTRIM(c.emp_id)::int ELSE NULL END))
                LEFT JOIN employees em_op ON em_op.id=t.operator_id
                    OR (t.operator_id IS NULL AND em_op.legacy_id=t.operator_legacy_id)
                LEFT JOIN ar_ap_ledger ledger ON ledger.id=i.applied_ledger_id
                LEFT JOIN currencies currency ON currency.id=COALESCE(i.currency_id,t.currency_id)
                LEFT JOIN payment_styles style ON style.id=t.other_fee_style_id
                LEFT JOIN LATERAL (
                    SELECT string_agg(ref.source_no, ', ' ORDER BY ref.source_no) AS sales_order_nos
                    FROM ar_ap_source_refs ref
                    WHERE ref.ledger_id=i.applied_ledger_id
                ) orders ON TRUE
                """;
        WhereBuilder w = financeDocumentWhere("WHERE COALESCE(t.is_deleted,false)=false"
                + " AND (COALESCE(i.write_off_local,0)<>0 OR COALESCE(t.bank_fee,0)<>0 OR COALESCE(t.other_fee,0)<>0)",
                "t.maker_id", readScope);
        addFinanceDocFilters(w, billNo, clientId, accountId, status, dateFrom, dateTo, keyword,
                "t.client_id", "t.bill_no", "t.bill_date",
                "CONCAT_WS(' ',c.name,i.applied_bill_no,orders.sales_order_nos)");
        return execute(cols, dataSelect, fromJoin, w,
                "t.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size, sort, order);
    }

    // ======================== ④ 往来对帐单 I·J·K·L / X（滚动余额，源=头表+台账） ========================

    /** I/K 单客户/供应商流水对帐（AR/AP 立帐 + 收款/付款头表合并，滚动余额；外/本/汇率列）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyStatementFlow(UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo,
                                                  int page, int size) {
        requireCompanyWideReportAccess();
        return partyStatementFlowAuthorized(partyId, side, dateFrom, dateTo, page, size);
    }

    private ReportTableResponse partyStatementFlowAuthorized(
            UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo, int page, int size) {
        if (partyId == null) return empty(List.of(
                ReportColumn.date("billDate", "开单日期"), ReportColumn.text("refNo", "关联单号", 150),
                ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.money("salesOriginal", "销售金额(外)"), ReportColumn.number("salesRate", "销售汇率"),
                ReportColumn.money("salesLocal", "销售金额(本)"), ReportColumn.money("receiptOriginal", "收款金额(外)"),
                ReportColumn.number("receiptRate", "收款汇率"), ReportColumn.money("receiptLocal", "收款金额(本)"),
                ReportColumn.money("balanceOriginal", "应收余额(外)"), ReportColumn.number("balanceRate", "应收汇率"),
                ReportColumn.money("balanceLocal", "应收余额(本)")));
        boolean isAR = "AR".equalsIgnoreCase(side);
        // 立帐行（ar_ap_ledger）+ 收/付款行（finance_receipts/payments 头表）
        NativeReadScope documentScope = COMPANY_WIDE_DOCUMENT_SCOPE;
        if (!isAR) {
            String sql = supplierPayableStatementEventsSql(documentScope) + """
                    SELECT event_date,ref_no,posted_original,posted_rate,posted_local,
                           settled_original,settled_rate,settled_local,event_type,
                           currency_code,remark,currency_id
                    FROM supplier_payable_events
                    WHERE supplier_id=:pid
                      AND (CAST(:to AS date) IS NULL OR event_date<=:to)
                    ORDER BY event_date,event_order,ref_no
                    """;
            return buildRunningBalance(partyStatementFlowCols(false), sql, partyId,
                    dateFrom, dateTo, page, size, true, documentScope);
        }
        String posted = isAR
                ? "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0 AS r_org, 0 AS r_rate, 0 AS r_loc, "
                + "'立账', cur.code, l.remark, cur.id FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id "
                + "WHERE l.is_deleted=false AND l.direction='AR' AND l.status=1 AND l.client_id=:pid"
                : "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0,0,0, "
                + "'立账', cur.code, l.remark, cur.id FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id "
                + "WHERE l.is_deleted=false AND l.direction='AP' AND l.status=1 AND l.supplier_id=:pid";
        String settled = isAR
                ? "SELECT t.bill_date, t.bill_no, 0,0,0, "
                + "CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_original ELSE t.amount_original END AS r_org, "
                + "t.exchange_rate AS r_rate, "
                + "CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_local ELSE t.amount_local END AS r_loc, "
                + "'冲减应收', cur.code, t.remark, cur.id FROM finance_receipts t "
                + "LEFT JOIN currencies cur ON cur.id=t.currency_id LEFT JOIN LATERAL (SELECT COUNT(*) AS line_count, "
                + "SUM(i.amount_original+i.write_off_amount) AS applied_original, SUM(i.applied_amount_local) AS applied_local "
                + "FROM finance_receipt_lines i WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false) lines ON TRUE "
                + "WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.client_id=:pid"
                : "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original, t.exchange_rate, t.amount_local, "
                + "'付款', cur.code, t.remark, cur.id FROM finance_payments t LEFT JOIN currencies cur ON cur.id=t.currency_id "
                + "WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.supplier_id=:pid";
        settled += " AND " + documentScope.predicate();
        String sql = "SELECT * FROM (" + posted + " UNION ALL " + settled + ") u "
                + "WHERE (CAST(:to AS date) IS NULL OR bill_date<=:to) "
                + "ORDER BY bill_date ASC, bill_no ASC";
        return buildRunningBalance(partyStatementFlowCols(isAR), sql, partyId, dateFrom, dateTo,
                page, size, true, documentScope);
    }

    private static List<ReportColumn> partyStatementFlowCols(boolean isAR) {
        String pre = isAR ? "销售" : "采购";
        String rec = isAR ? "冲减应收" : "付款";
        String bal = isAR ? "应收" : "应付";
        // 立账/收付款两侧都是本行自身的发生额，可加（原币按币别分组）；
        // 余额三列是<b>逐行滚动</b>出来的，把滚动余额一行行加起来毫无意义——只声明发生额的合计。
        return List.of(
                ReportColumn.date("billDate", "开单日期"), ReportColumn.text("refNo", "关联单号", 150),
                ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.money("salesOriginal", pre + "金额(外)")
                        .totaled("合计" + pre + "金额(外)", "currencyCode"),
                ReportColumn.number("salesRate", pre + "汇率"),
                ReportColumn.money("salesLocal", pre + "金额(本)").totaled("合计" + pre + "金额(本)"),
                ReportColumn.money("receiptOriginal", rec + "金额(外)")
                        .totaled("合计" + rec + "金额(外)", "currencyCode"),
                ReportColumn.number("receiptRate", rec + "汇率"),
                ReportColumn.money("receiptLocal", rec + "金额(本)").totaled("合计" + rec + "金额(本)"),
                ReportColumn.money("balanceOriginal", bal + "余额(外)"), ReportColumn.number("balanceRate", bal + "汇率"),
                ReportColumn.money("balanceLocal", bal + "余额(本)"));
    }

    /** J/L 单客户/供应商明细对帐（逐行更详细：立帐单号/收付款单号/币别/摘要）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyStatementDetail(UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo,
                                                    int page, int size) {
        requireCompanyWideReportAccess();
        return partyStatementDetailAuthorized(partyId, side, dateFrom, dateTo, page, size);
    }

    private ReportTableResponse partyStatementDetailAuthorized(
            UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo, int page, int size) {
        if (partyId == null) return empty(partyStatementFlowCols("AR".equalsIgnoreCase(side)));
        // 复用 flow 的 UNION，扩列 type/currencyCode/remark

        boolean isAR = "AR".equalsIgnoreCase(side);
        NativeReadScope documentScope = COMPANY_WIDE_DOCUMENT_SCOPE;
        if (!isAR) {
            String sql = supplierPayableStatementEventsSql(documentScope) + """
                    SELECT event_date,ref_no,posted_original,posted_rate,posted_local,
                           settled_original,settled_rate,settled_local,event_type,
                           currency_code,remark,currency_id
                    FROM supplier_payable_events
                    WHERE supplier_id=:pid
                      AND (CAST(:to AS date) IS NULL OR event_date<=:to)
                    ORDER BY event_date,event_order,ref_no
                    """;
            List<ReportColumn> cols = new ArrayList<>(partyStatementFlowCols(false));
            cols.add(2, ReportColumn.text("type", "类型", 80));
            cols.add(ReportColumn.text("remark", "摘要", 160));
            return buildRunningBalance(cols, sql, partyId, dateFrom, dateTo,
                    page, size, false, documentScope);
        }
        String posted = isAR
                ? "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0 AS r_org, 0 AS r_rate, 0 AS r_loc, '立帐' AS typ, cur.code AS cur, l.remark, cur.id "
                + "FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id WHERE l.is_deleted=false AND l.direction='AR' AND l.status=1 AND l.client_id=:pid"
                : "SELECT l.bill_date, l.bill_no, l.amount_original, l.exchange_rate, l.amount_original_local, 0,0,0, '立帐', cur.code, l.remark, cur.id "
                + "FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id WHERE l.is_deleted=false AND l.direction='AP' AND l.status=1 AND l.supplier_id=:pid";
        String settled = isAR
                ? "SELECT t.bill_date, t.bill_no, 0,0,0, "
                + "CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_original ELSE t.amount_original END, "
                + "t.exchange_rate, CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_local ELSE t.amount_local END, "
                + "'冲减应收', cur.code, t.remark, cur.id "
                + "FROM finance_receipts t LEFT JOIN currencies cur ON cur.id=t.currency_id "
                + "LEFT JOIN LATERAL (SELECT COUNT(*) AS line_count, "
                + "SUM(i.amount_original+i.write_off_amount) AS applied_original, SUM(i.applied_amount_local) AS applied_local "
                + "FROM finance_receipt_lines i WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false) lines ON TRUE "
                + "WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.client_id=:pid"
                : "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original, t.exchange_rate, t.amount_local, '付款', cur.code, t.remark, cur.id "
                + "FROM finance_payments t LEFT JOIN currencies cur ON cur.id=t.currency_id WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.supplier_id=:pid";
        settled += " AND " + documentScope.predicate();
        String sql = "SELECT * FROM (" + posted + " UNION ALL " + settled + ") u "
                + "WHERE (CAST(:to AS date) IS NULL OR bill_date<=:to) "
                + "ORDER BY bill_date ASC, bill_no ASC";
        List<ReportColumn> cols = new ArrayList<>(partyStatementFlowCols(isAR));
        cols.add(2, ReportColumn.text("type", "类型", 80));
        cols.add(ReportColumn.text("remark", "摘要", 160));
        return buildRunningBalance(cols, sql, partyId, dateFrom, dateTo,
                page, size, false, documentScope);
    }

    /** X 客户/供应商年度对帐单（按月：期初/立帐(发货)/收款(回款)/退货/期末；一年 12 行 + 汇总）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyAnnualStatement(UUID partyId, String side, int year,
                                                    int page, int size) {
        requireCompanyWideReportAccess();
        return partyAnnualStatementAuthorized(partyId, side, year, page, size);
    }

    private ReportTableResponse partyAnnualStatementAuthorized(
            UUID partyId, String side, int year, int page, int size) {
        boolean isAR = "AR".equalsIgnoreCase(side);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("ym", "月份", 100),
                // 期初/期末是每个月的滚动余额，12 行相加不是任何一个账上的数，不声明合计。
                ReportColumn.money("prevBalance", "期初" + (isAR ? "应收" : "应付")),
                // 立账/核销是当月发生额（人民币口径），逐月相加正好是所选年度的全年合计。
                ReportColumn.money("posted", isAR ? "发货金额" : "收货金额")
                        .totaled(isAR ? "合计发货金额" : "合计收货金额"),
                ReportColumn.money("settled", isAR ? "回款金额" : "付款金额")
                        .totaled(isAR ? "合计回款金额" : "合计付款金额"),
                // 退货金额当前恒投影为 0（退货已合并进 posted），合计只会显示一个误导性的 0，不声明。
                ReportColumn.money("returned", "退货金额"),
                ReportColumn.money("balance", "期末" + (isAR ? "应收" : "应付")));
        if (partyId == null || year <= 0) return empty(cols);
        LocalDate yearStart = LocalDate.of(year, 1, 1);
        LocalDate yearEnd = LocalDate.of(year, 12, 31);
        String partyCol = isAR ? "client_id" : "supplier_id";
        String dirLit = isAR ? "'AR'" : "'AP'";
        NativeReadScope documentScope = COMPANY_WIDE_DOCUMENT_SCOPE;
        if (!isAR) {
            String sql = supplierPayableStatementEventsSql(documentScope) + """
                    , party_ledger AS (
                        SELECT event_date AS bill_date,posted_local AS posted,
                               settled_local AS settled
                        FROM supplier_payable_events WHERE supplier_id=:pid
                    ), monthly AS (
                        SELECT date_trunc('month',bill_date) AS ms,
                               to_char(date_trunc('month',bill_date),'YYYY-MM') AS ym,
                               COALESCE(SUM(posted),0) AS posted,
                               COALESCE(SUM(settled),0) AS settled
                        FROM party_ledger WHERE bill_date BETWEEN :ys AND :ye GROUP BY 1,2
                    )
                    SELECT month.ym,
                           COALESCE((SELECT SUM(prior.posted-prior.settled)
                               FROM party_ledger prior WHERE prior.bill_date<month.ms),0),
                           month.posted,month.settled,0,
                           COALESCE((SELECT SUM(closing.posted-closing.settled)
                               FROM party_ledger closing
                               WHERE closing.bill_date<month.ms+INTERVAL '1 month'),0)
                    FROM monthly month ORDER BY month.ym
                    """;
            return executeRawGrouped(cols, sql, partyId, yearStart, yearEnd,
                    page, size, documentScope);
        }
        String settledSelect = isAR
                ? " SELECT t.bill_date, 0, CASE WHEN EXISTS (SELECT 1 FROM finance_receipt_lines x"
                + " WHERE x.receipt_id=t.id AND COALESCE(x.is_deleted,false)=false)"
                + " THEN COALESCE((SELECT SUM(x.applied_amount_local) FROM finance_receipt_lines x"
                + " WHERE x.receipt_id=t.id AND COALESCE(x.is_deleted,false)=false),0) ELSE t.amount_local END"
                + " FROM finance_receipts t WHERE COALESCE(t.is_deleted,false)=false"
                + " AND t.status=1 AND t.client_id=:pid"
                : " SELECT t.bill_date, 0, t.amount_local FROM finance_payments t"
                + " WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.supplier_id=:pid";
        settledSelect += " AND " + documentScope.predicate();
        // 按月：期初=该月初前累计余额；期末=下月初前累计余额（滚动）；posted/settled 为当月发生额。
        // returned 简化为 0（退货已在 ar_ap_ledger SALES_RETURN/PURCHASE_RETURN 体现为负 posted）。
        String sql = "WITH party_ledger AS ("
                + " SELECT bill_date, amount_original_local AS posted, 0 AS settled FROM ar_ap_ledger l"
                + " WHERE l.is_deleted=false AND l.direction=" + dirLit + " AND l.status=1 AND l." + partyCol + "=:pid"
                + " UNION ALL"
                + settledSelect
                + "), monthly AS ("
                + " SELECT date_trunc('month', pl.bill_date) AS ms, to_char(date_trunc('month', pl.bill_date),'YYYY-MM') AS ym,"
                + " COALESCE(SUM(pl.posted),0) AS posted, COALESCE(SUM(pl.settled),0) AS settled"
                + " FROM party_ledger pl WHERE pl.bill_date BETWEEN :ys AND :ye GROUP BY 1, 2)"
                + " SELECT m.ym,"
                + " COALESCE((SELECT SUM(p2.posted-p2.settled) FROM party_ledger p2 WHERE p2.bill_date < m.ms),0) AS prevBalance,"
                + " m.posted, m.settled, 0 AS returned,"
                + " COALESCE((SELECT SUM(p3.posted-p3.settled) FROM party_ledger p3 WHERE p3.bill_date < m.ms + INTERVAL '1 month'),0) AS balance"
                + " FROM monthly m ORDER BY m.ym";
        return executeRawGrouped(cols, sql, partyId, yearStart, yearEnd, page, size, documentScope);
    }

    /**
     * One dated AP event authority shared by supplier flow/detail/annual reports.
     * Posted columns increase AP; settled columns reduce AP. Reversals retain
     * their actual event date, and payment local amount is the AP book amount
     * rather than cash local amount, so FX never distorts the supplier balance.
     */
    private static String supplierPayableStatementEventsSql(NativeReadScope documentScope) {
        return """
                WITH payment_facts AS (
                    SELECT payment.id,payment.supplier_id,payment.currency_id,payment.bill_no,
                           payment.bill_date,
                           (COALESCE(payment.reversed_at, payment.updated_at)
                               AT TIME ZONE 'Asia/Shanghai')::DATE AS reverse_date,
                           payment.exchange_rate,payment.status,payment.remark,
                           CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN lines.applied_original ELSE payment.amount_original END AS book_original,
                           CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN lines.applied_local ELSE payment.amount_local END AS book_local,
                           CASE WHEN COALESCE(lines.line_count,0)>0
                                THEN ROUND(lines.applied_local/NULLIF(lines.applied_original,0),6)
                                ELSE payment.exchange_rate END AS book_rate
                    FROM finance_payments payment
                    LEFT JOIN LATERAL (
                        SELECT COUNT(*) AS line_count,
                               COALESCE(SUM(line.amount_original),0) AS applied_original,
                               COALESCE(SUM(COALESCE(line.applied_amount_local,
                                   line.amount_local-COALESCE(line.exchange_diff,0))),0) AS applied_local
                        FROM finance_payment_lines line
                        WHERE line.payment_id=payment.id
                          AND COALESCE(line.is_deleted,FALSE)=FALSE
                    ) lines ON TRUE
                    WHERE payment.status IN(1,-1)
                      AND COALESCE(payment.is_deleted,FALSE)=FALSE
                      AND payment.supplier_id IS NOT NULL
                      AND %s
                ), supplier_payable_events AS (
                    SELECT ledger.bill_date AS event_date,ledger.bill_no AS ref_no,
                           ledger.amount_original AS posted_original,ledger.exchange_rate AS posted_rate,
                           ledger.amount_original_local AS posted_local,
                           0::NUMERIC AS settled_original,NULL::NUMERIC AS settled_rate,
                           0::NUMERIC AS settled_local,'立账' AS event_type,
                           currency.code AS currency_code,ledger.remark,ledger.currency_id,
                           ledger.supplier_id,10 AS event_order
                    FROM ar_ap_ledger ledger
                    LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                    WHERE ledger.direction='AP' AND ledger.supplier_id IS NOT NULL
                      AND ledger.source_doc_type<>'DIRECT_PAYMENT'
                      AND ((ledger.status=1 AND COALESCE(ledger.is_deleted,FALSE)=FALSE)
                        OR (ledger.status=-1 AND COALESCE(ledger.is_deleted,FALSE)=TRUE
                            AND ledger.deleted_at IS NOT NULL))
                    UNION ALL
                    SELECT (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           ledger.bill_no,
                           -ledger.amount_original,ledger.exchange_rate,
                           -ledger.amount_original_local,0::NUMERIC,NULL::NUMERIC,0::NUMERIC,
                           '立账红冲',currency.code,ledger.remark,ledger.currency_id,
                           ledger.supplier_id,20
                    FROM ar_ap_ledger ledger
                    LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                    WHERE ledger.direction='AP' AND ledger.supplier_id IS NOT NULL
                      AND ledger.status=-1 AND COALESCE(ledger.is_deleted,FALSE)=TRUE
                      AND ledger.deleted_at IS NOT NULL
                    UNION ALL
                    SELECT payment.bill_date,payment.bill_no,0::NUMERIC,NULL::NUMERIC,0::NUMERIC,
                           payment.book_original,payment.book_rate,payment.book_local,
                           '付款',currency.code,payment.remark,payment.currency_id,
                           payment.supplier_id,30
                    FROM payment_facts payment
                    LEFT JOIN currencies currency ON currency.id=payment.currency_id
                    UNION ALL
                    SELECT payment.reverse_date,payment.bill_no,0::NUMERIC,NULL::NUMERIC,0::NUMERIC,
                           -payment.book_original,payment.book_rate,-payment.book_local,
                           '付款反审',currency.code,payment.remark,payment.currency_id,
                           payment.supplier_id,40
                    FROM payment_facts payment
                    LEFT JOIN currencies currency ON currency.id=payment.currency_id
                    WHERE payment.status=-1 AND payment.reverse_date IS NOT NULL
                    UNION ALL
                    SELECT allocation.effective_date,allocation.offset_batch_id::TEXT,
                           0::NUMERIC,NULL::NUMERIC,0::NUMERIC,allocation.amount_original,
                           allocation.target_rate,allocation.target_amount_local,
                           '应付抵销',currency.code,allocation.reason,allocation.currency_id,
                           allocation.supplier_id,50
                    FROM supplier_open_item_offsets allocation
                    LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    UNION ALL
                    SELECT allocation.effective_date,allocation.offset_batch_id::TEXT,
                           allocation.amount_original,allocation.source_rate,allocation.source_amount_local,
                           0::NUMERIC,NULL::NUMERIC,0::NUMERIC,
                           '贷项使用',currency.code,allocation.reason,allocation.currency_id,
                           allocation.supplier_id,60
                    FROM supplier_open_item_offsets allocation
                    LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    UNION ALL
                    SELECT (allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           allocation.offset_batch_id::TEXT,
                           0::NUMERIC,NULL::NUMERIC,0::NUMERIC,-allocation.amount_original,
                           allocation.target_rate,-allocation.target_amount_local,
                           '抵销反转',currency.code,allocation.reverse_reason,allocation.currency_id,
                           allocation.supplier_id,70
                    FROM supplier_open_item_offsets allocation
                    LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    WHERE allocation.status='REVERSED' AND allocation.reversed_at IS NOT NULL
                    UNION ALL
                    SELECT (allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           allocation.offset_batch_id::TEXT,
                           -allocation.amount_original,allocation.source_rate,-allocation.source_amount_local,
                           0::NUMERIC,NULL::NUMERIC,0::NUMERIC,
                           '贷项恢复',currency.code,allocation.reverse_reason,allocation.currency_id,
                           allocation.supplier_id,80
                    FROM supplier_open_item_offsets allocation
                    LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    WHERE allocation.status='REVERSED' AND allocation.reversed_at IS NOT NULL
                )
                """.formatted(documentScope.predicate());
    }

    // ======================== ⑤ 账户流水 S / 银行存取 Q·R ========================

    /** S 帐户进出流水帐（finance_reconciliations 滚动余额，必填 accountId）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse accountStatement(UUID accountId, LocalDate dateFrom, LocalDate dateTo,
                                                String keyword, int page, int size) {
        if (dateFrom != null && dateTo != null && dateFrom.isAfter(dateTo)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "开始日期不能晚于结束日期");
        }
        requireAccountStatementAccess();
        return accountStatementAuthorized(accountId, dateFrom, dateTo, keyword, page, size);
    }

    private ReportTableResponse accountStatementAuthorized(
            UUID accountId, LocalDate dateFrom, LocalDate dateTo,
            String keyword, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "日期"), ReportColumn.text("billNo", "单号", 140),
                ReportColumn.text("checkNo", "支票号", 120), ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("counterpartName", "对方单位", 160), ReportColumn.text("source", "支票来源", 120),
                // 单账户流水：收/支是每笔的发生额，可加（单账户单币种，无需分组）；
                // 余额是窗口函数滚动出来的，逐行相加无意义，不声明合计。
                ReportColumn.date("settledDate", "核销日期"),
                ReportColumn.money("inAmount", "收款金额").totaled("合计收款金额"),
                ReportColumn.money("outAmount", "支出金额").totaled("合计支出金额"),
                ReportColumn.money("balance", "余额"),
                ReportColumn.text("entryKind", "流水类型", 100));
        if (accountId == null) return empty(cols);
        int safePage=Math.max(1,page);
        int safeSize=Math.min(Math.max(1,size),500);
        long offset=(long)(safePage-1)*safeSize;
        java.time.OffsetDateTime fromAt=dateFrom==null?null:BusinessTime.startOfDay(dateFrom);
        LocalDate fromMonth=dateFrom==null?null:dateFrom.withDayOfMonth(1);
        java.time.OffsetDateTime fromMonthAt=fromMonth==null
                ?null:BusinessTime.startOfDay(fromMonth);
        java.time.OffsetDateTime toExclusive=dateTo==null?null:BusinessTime.startOfDay(dateTo.plusDays(1));
        String normalizedKeyword=keyword==null||keyword.isBlank()
                ?null:"%"+keyword.trim().toLowerCase(Locale.ROOT)+"%";
        String sql="""
                WITH account_base AS (
                  SELECT id,currency_id,init_balance
                  FROM accounts
                  WHERE id=:aid AND COALESCE(is_deleted,FALSE)=FALSE
                ), closed_months AS (
                  SELECT COALESCE(SUM(summary.in_amount-summary.out_amount),0) AS amount
                  FROM account_base base
                  LEFT JOIN account_flow_monthly_summaries summary
                    ON summary.account_id=base.id
                   AND summary.account_currency_id=base.currency_id
                   AND CAST(:fromMonth AS date) IS NOT NULL
                   AND summary.month_start<CAST(:fromMonth AS date)
                ), current_month_tail AS (
                  SELECT COALESCE(SUM(flow.in_amount-flow.out_amount),0) AS amount
                  FROM account_base base
                  LEFT JOIN finance_reconciliations flow
                    ON flow.account_id=base.id
                   AND COALESCE(flow.is_deleted,FALSE)=FALSE
                   AND CAST(:fromAt AS timestamptz) IS NOT NULL
                   AND flow.bill_date>=CAST(:fromMonthAt AS timestamptz)
                   AND flow.bill_date<CAST(:fromAt AS timestamptz)
                ), opening AS (
                  SELECT base.init_balance+closed.amount+tail.amount AS amount
                  FROM account_base base
                  CROSS JOIN closed_months closed
                  CROSS JOIN current_month_tail tail
                ), windowed AS (
                  SELECT (flow.bill_date AT TIME ZONE 'Asia/Shanghai')::date AS bill_date,
                         flow.bill_no,COALESCE(flow.check_no,'') AS check_no,
                         COALESCE(flow.remark,'') AS summary,
                         COALESCE(flow.counterpart_name,'') AS counterpart_name,
                         COALESCE(flow.source_remark,'') AS source,
                         flow.settled_date,flow.in_amount,flow.out_amount,
                         opening.amount+SUM(flow.in_amount-flow.out_amount) OVER(
                           ORDER BY flow.bill_date,flow.posting_seq
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS balance,
                         flow.source_doc_type,flow.source_doc_id,flow.entry_kind,
                         flow.reversal_of_id,
                         LOWER(COALESCE(flow.bill_no,'')||' '||COALESCE(flow.check_no,'')||' '
                           ||COALESCE(flow.counterpart_name,'')||' '||COALESCE(flow.remark,'')||' '
                           ||COALESCE(flow.source_remark,'')||' '||COALESCE(flow.source_doc_type,'')) AS searchable,
                         flow.bill_date AS sort_bill_date,flow.posting_seq AS sort_posting_seq,
                         flow.id AS entry_id
                  FROM finance_reconciliations flow
                  CROSS JOIN opening
                  WHERE flow.account_id=:aid AND COALESCE(flow.is_deleted,FALSE)=FALSE
                    AND (CAST(:fromAt AS timestamptz) IS NULL
                         OR flow.bill_date>=CAST(:fromAt AS timestamptz))
                    AND (CAST(:toExclusive AS timestamptz) IS NULL
                         OR flow.bill_date<CAST(:toExclusive AS timestamptz))
                ), filtered AS (
                  -- total_in/total_out 与 total_count 同款：窗口聚合覆盖**整个筛选后结果集**
                  -- （窗口在 WHERE 之后、LIMIT 之前求值），所以表尾合计不是「本页合计」，
                  -- 而且不用为此多跑一条聚合查询。余额是滚动值，不在这里聚合。
                  SELECT windowed.*,COUNT(*) OVER() AS total_count,
                         SUM(in_amount) OVER() AS total_in,
                         SUM(out_amount) OVER() AS total_out
                  FROM windowed
                  WHERE CAST(:keyword AS text) IS NULL
                     OR searchable LIKE CAST(:keyword AS text)
                )
                SELECT bill_date,bill_no,check_no,summary,counterpart_name,source,
                       settled_date,in_amount,out_amount,balance,
                       source_doc_type,source_doc_id,entry_kind,reversal_of_id,
                       entry_id,sort_posting_seq,total_count,total_in,total_out
                FROM filtered
                ORDER BY sort_bill_date,sort_posting_seq
                LIMIT :limit OFFSET :offset
                """;
        var query=em.createNativeQuery(sql)
                .setParameter("aid",accountId)
                .setParameter("fromAt",fromAt)
                .setParameter("fromMonth",fromMonth)
                .setParameter("fromMonthAt",fromMonthAt)
                .setParameter("toExclusive",toExclusive)
                .setParameter("keyword",normalizedKeyword)
                .setParameter("limit",safeSize)
                .setParameter("offset",offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows=query.getResultList();
        List<Map<String,Object>> items=new ArrayList<>(rows.size());
        long total=rows.isEmpty()?0:((Number)rows.getFirst()[16]).longValue();
        for(Object[] row:rows){
            Map<String,Object> item=new LinkedHashMap<>();
            item.put("billDate",norm(row[0]));
            item.put("billNo",norm(row[1]));
            item.put("checkNo",norm(row[2]));
            item.put("summary",norm(row[3]));
            item.put("counterpartName",norm(row[4]));
            item.put("source",norm(row[5]));
            item.put("settledDate",norm(row[6]));
            item.put("inAmount",norm(row[7]));
            item.put("outAmount",norm(row[8]));
            item.put("balance",norm(row[9]));
            item.put("sourceDocType",norm(row[10]));
            item.put("sourceDocId",norm(row[11]));
            item.put("entryKind",norm(row[12]));
            item.put("reversalOfId",norm(row[13]));
            item.put("entryId",norm(row[14]));
            item.put("postingSeq",norm(row[15]));
            item.put("inAmountText",num(row[7]).toPlainString());
            item.put("outAmountText",num(row[8]).toPlainString());
            item.put("balanceText",num(row[9]).toPlainString());
            items.add(item);
        }
        int totalPages=(int)((total+safeSize-1)/safeSize);
        List<com.uten.imp.common.report.ReportTotal> totals=new ArrayList<>();
        if(!rows.isEmpty()){
            addScalarTotal(totals,cols,"inAmount",rows.getFirst()[17]);
            addScalarTotal(totals,cols,"outAmount",rows.getFirst()[18]);
        }
        return new ReportTableResponse(
                cols,items,new LinkedHashMap<>(),safePage,safeSize,total,totalPages,totals);
    }

    /** Q 银行存取明细 / R 汇总（M_Bank 0 行，返回空结构）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse bankReport(String view) {
        // 当前为空结构；仍按公司级入口 fail-closed，避免后续接入银行事实时意外放开。
        requireCompanyWideReportAccess();
        if ("summary".equalsIgnoreCase(view)) {
            return empty(List.of(ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "日期"),
                    ReportColumn.text("outAccount", "取款账户", 140), ReportColumn.money("amount", "金额"),
                    ReportColumn.text("currencyCode", "币别", 80), ReportColumn.number("rate", "汇率")));
        }
        return empty(List.of(ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "日期"),
                ReportColumn.text("outAccount", "取款账户", 140), ReportColumn.text("inAccount", "存款账户", 140),
                ReportColumn.money("amount", "金额"), ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.number("rate", "汇率"), ReportColumn.text("checkNo", "支票号", 120),
                ReportColumn.text("summary", "摘要", 160)));
    }

    /**
     * Dated customer-advance subledger. Arrival is a liability cash fact and does
     * not reduce AR; only explicit application/reversal changes the target AR.
     * Reversed rows remain visible on their actual reversal date.
     */
    @Transactional(readOnly = true)
    public ReportTableResponse customerPrepaymentEvents(
            UUID clientId, LocalDate dateFrom, LocalDate dateTo, int page, int size) {
        requireCompanyWideReportAccess();
        if (!access.hasAuthority("customer_prepayment:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少客户预收查看权限");
        }
        List<ReportColumn> columns = List.of(
                ReportColumn.date("eventDate", "记账日期"),
                ReportColumn.text("eventNo", "资金单号", 180),
                ReportColumn.text("eventType", "事件代码", 190),
                ReportColumn.text("eventTypeLabel", "事件类型", 150),
                ReportColumn.text("salesOrderNos", "销售单", 220),
                ReportColumn.text("clientCode", "客户编号", 120),
                ReportColumn.text("clientName", "客户名称", 180),
                ReportColumn.text("currencyCode", "币别", 90),
                // 一行 = 一个带日期的预收事件（红冲/反转本身就是负数行），全部为事件自身的金额，
                // 相加即「所选区间内的净额」；原币按币别分组，本币列不分组。
                ReportColumn.money("prepaymentCashOriginal", "预收现金(原币)")
                        .totaled("合计预收现金(原币)", "currencyCode"),
                ReportColumn.money("prepaymentCashLocal", "预收现金(本币)").totaled("合计预收现金(本币)"),
                ReportColumn.money("appliedOriginal", "转销应收(原币)")
                        .totaled("合计转销应收(原币)", "currencyCode"),
                ReportColumn.money("sourceBookLocal", "预收账面本币").totaled("合计预收账面本币"),
                ReportColumn.money("targetBookLocal", "应收账面本币").totaled("合计应收账面本币"),
                ReportColumn.money("exchangeDifferenceLocal", "汇兑差额").totaled("合计汇兑差额"),
                ReportColumn.text("reason", "摘要", 220));
        String filter = (clientId == null ? "" : " AND event.client_id=:clientId")
                + (dateFrom == null ? "" : " AND event.event_date>=:dateFrom")
                + (dateTo == null ? "" : " AND event.event_date<=:dateTo");
        String sql = """
                WITH event AS (
                  SELECT receipt.bill_date AS event_date,receipt.bill_no AS event_no,
                         'CUSTOMER_PREPAYMENT_RECEIPT'::text AS event_type,
                         '预收到账'::text AS event_type_label,
                         COALESCE(sales_order.bill_no,'客户池') AS sales_order_nos,
                         COALESCE(sales_order.id::text,'') AS sales_order_ids,
                         receipt.client_id,receipt.currency_id,
                         receipt.amount_original AS cash_original,receipt.amount_local AS cash_local,
                         0::numeric AS applied_original,0::numeric AS source_local,
                         0::numeric AS target_local,0::numeric AS exchange_difference,
                         COALESCE(receipt.remark,'客户预收到账') AS reason,1 AS event_order
                  FROM finance_receipts receipt
                  LEFT JOIN sales_orders sales_order ON sales_order.id=receipt.sales_order_id
                  WHERE receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                    AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                  UNION ALL
                  SELECT (COALESCE(receipt.reversed_at, receipt.updated_at)
                              AT TIME ZONE 'Asia/Shanghai')::date,receipt.bill_no,
                         'CUSTOMER_PREPAYMENT_RECEIPT_REVERSED','预收到账红冲',
                         COALESCE(sales_order.bill_no,'客户池'),COALESCE(sales_order.id::text,''),
                         receipt.client_id,receipt.currency_id,-receipt.amount_original,-receipt.amount_local,
                         0,0,0,0,COALESCE(receipt.remark,'客户预收到账红冲'),4
                  FROM finance_receipts receipt
                  LEFT JOIN sales_orders sales_order ON sales_order.id=receipt.sales_order_id
                  WHERE receipt.receipt_kind='CUSTOMER_PREPAYMENT' AND receipt.status=-1
                    AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                  UNION ALL
                  SELECT batch.effective_date,'CPA-'||replace(batch.id::text,'-',''),
                         'CUSTOMER_PREPAYMENT_APPLIED','预收转销应收',
                         string_agg(DISTINCT sales_order.bill_no,',' ORDER BY sales_order.bill_no),
                         string_agg(DISTINCT sales_order.id::text,',' ORDER BY sales_order.id::text),
                         batch.client_id,batch.currency_id,0,0,
                         SUM(allocation.amount_original),SUM(allocation.source_amount_local),
                         SUM(allocation.target_amount_local),SUM(allocation.exchange_difference),
                         batch.reason,2
                  FROM customer_open_item_offset_batches batch
                  JOIN customer_open_item_offsets allocation ON allocation.offset_batch_id=batch.id
                  JOIN sales_orders sales_order ON sales_order.id=allocation.sales_order_id
                  GROUP BY batch.id,batch.effective_date,batch.client_id,batch.currency_id,batch.reason
                  UNION ALL
                  SELECT (batch.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,
                         'CPA-'||replace(batch.id::text,'-',''),
                         'CUSTOMER_PREPAYMENT_APPLICATION_REVERSED','预收转销反转',
                         string_agg(DISTINCT sales_order.bill_no,',' ORDER BY sales_order.bill_no),
                         string_agg(DISTINCT sales_order.id::text,',' ORDER BY sales_order.id::text),
                         batch.client_id,batch.currency_id,0,0,
                         -SUM(allocation.amount_original),-SUM(allocation.source_amount_local),
                         -SUM(allocation.target_amount_local),-SUM(allocation.exchange_difference),
                         batch.reverse_reason,3
                  FROM customer_open_item_offset_batches batch
                  JOIN customer_open_item_offsets allocation ON allocation.offset_batch_id=batch.id
                  JOIN sales_orders sales_order ON sales_order.id=allocation.sales_order_id
                  WHERE batch.status='REVERSED' AND batch.reversed_at IS NOT NULL
                  GROUP BY batch.id,batch.reversed_at,batch.client_id,batch.currency_id,batch.reverse_reason
                )
                SELECT event.event_date,event.event_no,event.event_type,event.event_type_label,
                       event.sales_order_nos,event.sales_order_ids,
                       client.code,client.name,currency.code,
                       event.cash_original,event.cash_local,event.applied_original,
                       event.source_local,event.target_local,event.exchange_difference,event.reason
                FROM event
                JOIN clients client ON client.id=event.client_id
                JOIN currencies currency ON currency.id=event.currency_id
                WHERE 1=1
                """ + filter + " ORDER BY event.event_date,event.event_order,event.event_no";
        var query = em.createNativeQuery(sql);
        if (clientId != null) query.setParameter("clientId", clientId);
        if (dateFrom != null) query.setParameter("dateFrom", dateFrom);
        if (dateTo != null) query.setParameter("dateTo", dateTo);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        List<Map<String,Object>> mapped = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            Map<String,Object> item = new LinkedHashMap<>();
            item.put("eventDate", norm(row[0])); item.put("eventNo", norm(row[1]));
            item.put("eventType", norm(row[2])); item.put("eventTypeLabel", norm(row[3]));
            item.put("salesOrderNos", norm(row[4]));
            // UUID truth is returned for drill-down/API consumers but intentionally not a visible report column.
            item.put("salesOrderIds", norm(row[5]));
            item.put("clientCode", norm(row[6])); item.put("clientName", norm(row[7]));
            item.put("currencyCode", norm(row[8]));
            item.put("prepaymentCashOriginal", norm(row[9]));
            item.put("prepaymentCashLocal", norm(row[10]));
            item.put("appliedOriginal", norm(row[11])); item.put("sourceBookLocal", norm(row[12]));
            item.put("targetBookLocal", norm(row[13]));
            item.put("exchangeDifferenceLocal", norm(row[14])); item.put("reason", norm(row[15]));
            mapped.add(item);
        }
        return paginate(columns, mapped, page, size);
    }

    // ======================== 通用辅助 ========================

    /** 公司级账簿不能按单据 maker 切片，否则会同时泄露事实并产生错误余额。 */
    private void requireCompanyWideReportAccess() {
        var scope = access.scope();
        if (!scope.seeAll()) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该报表包含公司级完整财务事实，仅超级管理员或具有 finance:view:all 权限的用户可访问");
        }
    }

    private void requireAccountStatementAccess() {
        if (!access.hasAuthority("account:view")
                || !access.hasAuthority("account:balance:view")
                || !access.hasAuthority("account:flow:view")) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "账户流水要求同时具备账户查看、余额查看和账户流水查看权限");
        }
    }

    /**
     * 五类财务单据报表统一复用对象级读取范围。
     *
     * <p>普通用户可见 legacy {@code maker_id IS NULL}、本人及已委托归属人的单据；
     * 超级管理员或持 {@code finance:view:all} 时策略返回 {@code 1=1}。范围作为
     * {@link WhereBuilder} 的普通参数加入，使 data/count/facet 以及复用这些方法的导出
     * 始终使用同一谓词和绑定，避免只过滤页面数据而泄漏总数或导出内容。
     * 公司级 AR/AP、GL、成本、固定资产及账户流水不会套用 maker 切片，而是在查询前
     * 通过 {@link #requireCompanyWideReportAccess()} 整体拒绝非全见用户。
     */
    private WhereBuilder financeDocumentWhere(
            String baseSql, String ownerColumn, OwnerScope readScope) {
        WhereBuilder where = new WhereBuilder(baseSql);
        addFinanceDocumentScope(where, ownerColumn, readScope);
        return where;
    }

    private void addFinanceDocumentScope(
            WhereBuilder where, String ownerColumn, OwnerScope readScope) {
        NativeReadScope scope = financeDocumentScope(ownerColumn, readScope);
        where.add(scope.predicate(), scope.parameterName(), scope.owners());
    }

    private NativeReadScope financeDocumentScope(String ownerColumn, OwnerScope readScope) {
        return access.nativeReadScope(ownerColumn, FINANCE_REPORT_OWNERS, readScope);
    }

    /**
     * 默认口径：草稿（status=0）不进报表。
     *
     * <p>未审核的钱流单据没有过账，不构成收付事实。调用方显式传 status（含 status=0 查草稿）
     * 时按其口径走，不叠加本默认值。与 SalesReportService 同款（钱流单头别名为 {@code t}）。
     */
    private static void addApprovedByDefault(WhereBuilder w, Short status) {
        if (status != null) {
            w.add("t.status=:status", "status", status);
        } else {
            // 无具名参数的常量片段：WhereBuilder.build 对 param==null 的 Clause 只拼 SQL 不绑参。
            w.add("t.status <> 0", null, null);
        }
    }

    private static void addFinanceDocFilters(WhereBuilder w, String billNo, UUID partyId, UUID accountId,
                                             Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                             String partyIdCol, String billNoCol, String dateCol, String partyNameCol) {
        if (billNo != null && !billNo.isBlank()) w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        if (partyId != null) w.add(partyIdCol + "=:pid", "pid", partyId);
        if (accountId != null) w.add("t.account_id=:accountId", "accountId", accountId);
        addApprovedByDefault(w, status);
        if (dateFrom != null) w.add(dateCol + ">=:dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add(dateCol + "<=:dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank())
            w.add("(LOWER(" + billNoCol + ") LIKE LOWER(:kw) OR LOWER(COALESCE(" + partyNameCol + ",'')) LIKE LOWER(:kw))", "kw", "%" + kw.toLowerCase() + "%");
    }

    private static void addFinanceItemFilters(WhereBuilder w, String billNo, UUID accountId, UUID departmentId,
                                              Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                              String billNoCol, String dateCol) {
        if (billNo != null && !billNo.isBlank()) w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        if (accountId != null) w.add("t.account_id=:accountId", "accountId", accountId);
        if (departmentId != null) w.add("i.department_id=:departmentId", "departmentId", departmentId);
        addApprovedByDefault(w, status);
        if (dateFrom != null) w.add(dateCol + ">=:dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add(dateCol + "<=:dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank())
            w.add("(LOWER(" + billNoCol + ") LIKE LOWER(:kw) OR LOWER(COALESCE(i.summary,'')) LIKE LOWER(:kw))", "kw", "%" + kw.toLowerCase() + "%");
    }

    /** 日期片段（用于 Z 的子查询）。 */
    private static String dateClause(String col) {
        return " AND (CAST(:fromDate AS date) IS NULL OR " + col + ">=:fromDate)"
                + " AND (CAST(:toDate AS date) IS NULL OR " + col + "<=:toDate)";
    }

    private ReportTableResponse empty(List<ReportColumn> cols) {
        return new ReportTableResponse(cols, List.of(), new LinkedHashMap<>(), 1, 50, 0, 0);
    }

    /** 滚动余额：取截止日以前的全量事实，Java 先累加期初再过滤开始日并手动分页。
     *  金额列统一在索引 [2..7]（org/rate/loc/r_org/r_rate/r_loc），[8]type [9]cur [10]remark [11]currencyId。
     *  原币余额按币别分别滚动，禁止把 USD/CNY 等原币金额直接相加；本币余额仍可统一累加。 */
    @Transactional(readOnly = true)
    private ReportTableResponse buildRunningBalance(List<ReportColumn> cols, String sql, UUID pid,
                                                    LocalDate dateFrom, LocalDate dateTo, int page, int size,
                                                    boolean simpleCols, NativeReadScope documentScope) {
        var q = em.createNativeQuery(sql).setParameter("pid", pid).setParameter("to", dateTo);
        documentScope.bind(q);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        Map<String, BigDecimal> runOrgByCurrency = new LinkedHashMap<>();
        BigDecimal runLoc = BigDecimal.ZERO;
        List<Map<String, Object>> all = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            BigDecimal org = num(r[2]); BigDecimal rate = numOrNull(r[3]); BigDecimal loc = num(r[4]);
            BigDecimal rOrg = num(r[5]); BigDecimal rRate = numOrNull(r[6]); BigDecimal rLoc = num(r[7]);
            String currencyCode = Objects.toString(r[9], "(未指定)");
            String currencyBucket = r[11] == null ? "(未指定)" : r[11].toString();
            BigDecimal runOrg = runOrgByCurrency.getOrDefault(currencyBucket, BigDecimal.ZERO)
                    .add(org).subtract(rOrg);
            runOrgByCurrency.put(currencyBucket, runOrg);
            runLoc = runLoc.add(loc).subtract(rLoc);
            LocalDate billDate = asLocalDate(r[0]);
            if (dateFrom != null && billDate != null && billDate.isBefore(dateFrom)) {
                continue;
            }
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("billDate", norm(r[0])); m.put("refNo", norm(r[1]));
            if (!simpleCols) m.put("type", norm(r[8]));
            m.put("currencyCode", norm(r[9]));
            m.put("salesOriginal", norm(org)); m.put("salesRate", norm(rate)); m.put("salesLocal", norm(loc));
            m.put("receiptOriginal", norm(rOrg)); m.put("receiptRate", norm(rRate)); m.put("receiptLocal", norm(rLoc));
            m.put("balanceOriginal", norm(runOrg)); m.put("balanceRate", norm(rate)); m.put("balanceLocal", norm(runLoc));
            if (!simpleCols) { m.put("remark", norm(r[10])); }
            all.add(m);
        }
        return paginate(cols, all, page, size);
    }

    private static LocalDate asLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        if (value instanceof java.sql.Timestamp timestamp) return timestamp.toLocalDateTime().toLocalDate();
        if (value instanceof java.time.LocalDateTime dateTime) return dateTime.toLocalDate();
        if (value instanceof java.time.OffsetDateTime dateTime) return dateTime.toLocalDate();
        String text = value.toString();
        return LocalDate.parse(text.length() > 10 ? text.substring(0, 10) : text);
    }

    /** 安全 BigDecimal：null→0，BigDecimal/Number→BigDecimal，否则解析字符串。 */
    /**
     * 把某列在<b>整个结果集</b>上的合计值，按该列的 {@code totaled(...)} 声明包成一项合计（无分组维度）。
     *
     * <p>给那些靠窗口聚合（{@code SUM(...) OVER()}）顺带取出全集合计、不另跑聚合查询的报表用
     * （目前是 S 帐户流水）。列上没声明 {@code totaled(...)} 或值为 null 时整项不出，
     * 与 {@code ReportTotalsCalculator} 的「宁可不显示也不伪造 0」一致。
     */
    private static void addScalarTotal(List<com.uten.imp.common.report.ReportTotal> out,
                                       List<ReportColumn> cols, String key, Object value) {
        if (value == null) return;
        ReportColumn col = cols.stream().filter(c -> c.key().equals(key)).findFirst().orElse(null);
        if (col == null || col.totalLabel() == null || col.totalLabel().isBlank()) return;
        out.add(new com.uten.imp.common.report.ReportTotal(
                col.key(), col.totalLabel(), col.type(), null,
                List.of(new com.uten.imp.common.report.ReportTotalGroup(null, num(value)))));
    }

    private static BigDecimal num(Object v) {
        if (v == null) return BigDecimal.ZERO;
        if (v instanceof BigDecimal bd) return bd;
        if (v instanceof Number n) return BigDecimal.valueOf(n.doubleValue());
        try { return new BigDecimal(v.toString()); } catch (Exception e) { return BigDecimal.ZERO; }
    }

    private static BigDecimal numOrNull(Object v) {
        return v == null ? null : num(v);
    }

    /** S 帐户流水滚动余额。 */
    @Transactional(readOnly = true)
    private ReportTableResponse buildAccountRunning(List<ReportColumn> cols, String sql, UUID aid,
                                                    LocalDate dateFrom, LocalDate dateTo, String kw, int page, int size) {
        String keyword = (kw == null || kw.isBlank()) ? null : kw.toLowerCase(Locale.ROOT);
        var q = em.createNativeQuery(sql)
                .setParameter("aid", aid)
                .setParameter("to", dateTo);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        // 从期初额开始遍历截止日以前的全部流水；日期/关键字只裁返回行，不能裁滚动余额事实。
        BigDecimal running = num(em.createNativeQuery(
                        "SELECT COALESCE(init_balance,0) FROM accounts WHERE id=:aid")
                .setParameter("aid", aid)
                .getSingleResult());
        List<Map<String, Object>> all = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            BigDecimal inAmt = num(r[7]);
            BigDecimal outAmt = num(r[8]);
            running = running.add(inAmt).subtract(outAmt);
            LocalDate billDate = asLocalDate(r[0]);
            if (dateFrom != null && billDate != null && billDate.isBefore(dateFrom)) {
                continue;
            }
            if (keyword != null) {
                String searchable = (Objects.toString(r[1], "") + " "
                        + Objects.toString(r[2], "") + " "
                        + Objects.toString(r[4], "") + " "
                        + Objects.toString(r[3], "") + " "
                        + Objects.toString(r[5], "") + " "
                        + Objects.toString(r[9], "")).toLowerCase(Locale.ROOT);
                if (!searchable.contains(keyword)) {
                    continue;
                }
            }
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("billDate", norm(r[0])); m.put("billNo", norm(r[1])); m.put("checkNo", norm(r[2]));
            m.put("summary", norm(r[3])); m.put("counterpartName", norm(r[4])); m.put("source", norm(r[5]));
            m.put("settledDate", norm(r[6])); m.put("inAmount", norm(inAmt)); m.put("outAmount", norm(outAmt));
            m.put("balance", norm(running));
            m.put("sourceDocType", norm(r[9]));
            m.put("sourceDocId", norm(r[10]));
            m.put("inAmountText", inAmt.toPlainString());
            m.put("outAmountText", outAmt.toPlainString());
            m.put("balanceText", running.toPlainString());
            all.add(m);
        }
        return paginate(cols, all, page, size);
    }

    /** X 年度对帐（GROUP BY 月，无滚动；直接分页）。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeRawGrouped(List<ReportColumn> cols, String sql, UUID pid,
                                                  LocalDate yearStart, LocalDate yearEnd, int page, int size,
                                                  NativeReadScope documentScope) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        var dataQ = em.createNativeQuery(sql + " LIMIT :__limit OFFSET :__offset")
                .setParameter("pid", pid).setParameter("ys", yearStart).setParameter("ye", yearEnd)
                .setParameter("__limit", safeSize).setParameter("__offset", offset);
        documentScope.bind(dataQ);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < cols.size(); i++) m.put(cols.get(i).key(), norm(r[i]));
            items.add(m);
        }
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM (" + sql + ") zz")
                .setParameter("pid", pid).setParameter("ys", yearStart).setParameter("ye", yearEnd);
        documentScope.bind(countQ);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        // 合计：整段按月 CTE 包成派生表再聚合（不带 LIMIT/OFFSET），所以是整年 12 个月的合计，
        // 而不是当前这一页的几个月。
        List<com.uten.imp.common.report.ReportTotal> totals = com.uten.imp.common.report.ReportTotalsCalculator.compute(
                em, sql, "", "",
                q -> {
                    q.setParameter("pid", pid).setParameter("ys", yearStart).setParameter("ye", yearEnd);
                    documentScope.bind(q);
                },
                reportTotalSpecs(cols, cols));
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages, totals);
    }

    private static ReportTableResponse paginate(List<ReportColumn> cols, List<Map<String, Object>> all, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long total = all.size();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        int from = (int) Math.min((long) (safePage - 1) * safeSize, total);
        int to = (int) Math.min((long) from + safeSize, total);
        // 合计在**切页之前**对 all（整个结果集）求和，不是对 subList 求和 ——
        // 这些报表本就必须先全量取回内存才能算滚动余额/事件序，所以直接复用同一份全量行：
        // 既不多跑一次查询，也不可能只合计当前页。
        List<com.uten.imp.common.report.ReportTotal> totals = com.uten.imp.common.report.ReportTotalsCalculator.computeFromRows(all, reportTotalSpecs(cols, cols));
        return new ReportTableResponse(cols, new ArrayList<>(all.subList(from, to)), new LinkedHashMap<>(), safePage, safeSize, total, totalPages, totals);
    }

    /** 按 GROUP BY 的聚合报表（如 F 销售收款汇总按客户）。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeGrouped(List<ReportColumn> cols, String dataSelect, String fromJoin,
                                               WhereBuilder w, String orderBy, String groupExpr, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        WhereBuilder.Built full = w.build(null);
        String groupBy = " GROUP BY " + groupExpr;
        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql() + groupBy
                + " ORDER BY " + orderBy + " LIMIT :__limit OFFSET :__offset");
        full.params().forEach(dataQ::setParameter);
        dataQ.setParameter("__limit", safeSize);
        dataQ.setParameter("__offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < cols.size(); i++) m.put(cols.get(i).key(), norm(r[i]));
            items.add(m);
        }
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM (" + dataSelect + " " + fromJoin + " " + full.sql() + groupBy + ") zz");
        full.params().forEach(countQ::setParameter);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        // 合计：派生表里必须连 GROUP BY 一起包进去（每行是一个分组的小计），
        // 外层再对全部分组求和 —— 即「全部客户×币别」的总计，与当前页无关。
        List<com.uten.imp.common.report.ReportTotal> totals = com.uten.imp.common.report.ReportTotalsCalculator.compute(
                em, dataSelect, fromJoin, full.sql() + groupBy,
                full.params(), reportTotalSpecs(cols, cols));
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages, totals);
    }

    private static String normalizeDirection(String direction) {
        if (direction == null) throw new ApiException(ErrorCode.BUSINESS, "direction 必填(AR/AP)");
        String d = direction.trim().toUpperCase();
        if (!d.equals("AR") && !d.equals("AP")) throw new ApiException(ErrorCode.BUSINESS, "direction 只能是 AR 或 AP");
        return d;
    }

    // ======================== 导出（加密 Excel） ========================

    /**
     * 导出某钱流报表全量（不分页，循环 size=500 累积全部行），返回 ExportColumn + 行 Map。
     * 列定义映射 ReportColumn→ExportColumn（剥离 width）。report 取值与 GET 路径一致：
     * ar-ap/overview / ar-ap/{detail,summary} / {receipt|payment|expense|income}/{detail,summary} /
     * fee-offset/detail / statement/{flow,detail,annual} / account/statement。
     *
     * <p>Q/R 银行存取款（{@link #bankReport}）为空表结构（M_Bank 0 行），不纳入导出——
     * 前端银行存取 chip 不显示导出按钮。
     *
     * <p>滚动余额报表（statement/flow·detail、account/statement）每次分页都从全量重算余额后切片，
     * 跨页累积时每页的「余额」均基于全集正确计算，导出值与页内一致。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(String report, Map<String, String> p, String sort, String order) {
        if ("account/statement".equals(report)) {
            requireAccountStatementAccess();
        }
        boolean companyWide = requiresCompanyWideExportAccess(report);
        OwnerScope exportDocumentScope;
        if (companyWide) {
            // 校验一次后复用 authorized loader，避免每个导出分页重复 evaluate scope。
            requireCompanyWideReportAccess();
            exportDocumentScope = null;
        } else {
            // 单据型导出同样只计算一次本人/委托范围，再复用于全部分页。
            exportDocumentScope = access.scope();
        }
        String billNo = p == null ? null : p.get("billNo");
        UUID clientId = parseUuid(p == null ? null : p.get("clientId"));
        UUID supplierId = parseUuid(p == null ? null : p.get("supplierId"));
        UUID accountId = parseUuid(p == null ? null : p.get("accountId"));
        UUID departmentId = parseUuid(p == null ? null : p.get("departmentId"));
        UUID partyId = parseUuid(p == null ? null : p.get("partyId"));
        UUID categoryId = parseUuid(p == null ? null : p.get("categoryId"));
        Short status = parseShort(p == null ? null : p.get("status"));
        LocalDate dateFrom = parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = parseDate(p == null ? null : p.get("dateTo"));
        String keyword = p == null ? null : p.get("keyword");
        String direction = p == null ? null : p.get("direction");
        String side = p == null ? null : p.get("side");
        String displayMode = p == null ? null : p.get("displayMode");
        String categoryType = p == null ? null : p.get("categoryType");
        Boolean settled = parseBool(p == null ? null : p.get("settled"));
        int year = parseIntOrZero(p == null ? null : p.get("year"));
        Map<String, String> facets = facetsOfMap(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (report) {
            case "ar-ap/overview"    -> (pg, sz) -> arApOverviewAuthorized(dateFrom, dateTo, displayMode, keyword, categoryType, categoryId, pg, sz);
            case "ar-ap/detail"      -> (pg, sz) -> arApDetailAuthorized(direction, billNo, partyId, settled, dateFrom, dateTo, keyword, facets, pg, sz, sort, order);
            case "ar-ap/order-plan"  -> (pg, sz) -> salesOrderReceivablePlanAuthorized(billNo, clientId, dateFrom, dateTo, keyword, pg, sz, sort, order);
            case "ar-ap/summary"     -> (pg, sz) -> arApSummaryAuthorized(direction, dateFrom, dateTo, keyword, facets, pg, sz, sort, order);
            case "receipt/detail"    -> (pg, sz) -> receiptDetailAuthorized(billNo, clientId, accountId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "receipt/summary"   -> (pg, sz) -> receiptSummaryAuthorized(billNo, clientId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "payment/detail"    -> (pg, sz) -> paymentDetailAuthorized(billNo, supplierId, accountId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "payment/summary"   -> (pg, sz) -> paymentSummaryAuthorized(billNo, supplierId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "expense/detail"    -> (pg, sz) -> expenseDetailAuthorized(billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "expense/summary"   -> (pg, sz) -> expenseSummaryAuthorized(billNo, departmentId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "income/detail"     -> (pg, sz) -> incomeDetailAuthorized(billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "income/summary"    -> (pg, sz) -> incomeSummaryAuthorized(billNo, departmentId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "fee-offset/detail" -> (pg, sz) -> feeOffsetDetailAuthorized(billNo, clientId, accountId, status, dateFrom, dateTo, keyword, facets, pg, sz, sort, order, exportDocumentScope);
            case "statement/flow"    -> (pg, sz) -> partyStatementFlowAuthorized(partyId, side, dateFrom, dateTo, pg, sz);
            case "statement/detail"  -> (pg, sz) -> partyStatementDetailAuthorized(partyId, side, dateFrom, dateTo, pg, sz);
            case "statement/annual"  -> (pg, sz) -> partyAnnualStatementAuthorized(partyId, side, year, pg, sz);
            case "account/statement" -> (pg, sz) -> accountStatementAuthorized(accountId, dateFrom, dateTo, keyword, pg, sz);
            // C2 对账单（FinanceStatementService；lossRate 仅 subcontract 用，默认 0.03）
            case "statements/subcontract" -> (pg, sz) -> statementService.subcontractStatement(
                    keyword, dateFrom, dateTo, parseBigDecimal(p == null ? null : p.get("lossRate")), pg, sz);
            case "statements/supplier" -> (pg, sz) -> statementService.supplierStatement(keyword, dateFrom, dateTo, pg, sz);
            case "statements/other-receivable" -> (pg, sz) -> statementService.otherReceivableStatement(keyword, dateFrom, dateTo, pg, sz);
            case "statements/client" -> (pg, sz) -> statementService.clientStatement(keyword, dateFrom, dateTo, pg, sz);
            // C4 成本核算（FinanceCostService）
            case "cost/product" -> (pg, sz) -> costService.productCost(keyword, dateFrom, dateTo, pg, sz);
            case "cost/sales-summary" -> (pg, sz) -> costService.salesCostSummary(keyword, dateFrom, dateTo, pg, sz);
            case "cost/copper-fee" -> (pg, sz) -> costService.copperFee(keyword, dateFrom, dateTo, pg, sz);
            case "cost/copper-pickling" -> (pg, sz) -> costService.copperPickling(keyword, dateFrom, dateTo, pg, sz);
            case "cost/plastic" -> (pg, sz) -> costService.plasticUsage(keyword, dateFrom, dateTo, pg, sz);
            case "cost/plastic-detail" -> (pg, sz) -> costService.plasticDetail(
                    p == null ? null : p.get("kind"), keyword, dateFrom, dateTo, pg, sz);
            // C3 总账（GlReportService；year/month 缺省取 dateTo 年/月）
            case "gl/trial-balance" -> (pg, sz) -> glReportService.trialBalance(dateFrom, dateTo, pg, sz);
            case "gl/balance-sheet" -> (pg, sz) -> glReportService.balanceSheet(dateTo);
            case "gl/profit-annual" -> (pg, sz) -> glReportService.profitAnnual(yearOf(p, dateTo));
            case "gl/profit-monthly" -> (pg, sz) -> glReportService.profitMonthly(yearOf(p, dateTo), monthOf(p, dateTo));
            case "gl/manufacturing-expense" -> (pg, sz) -> glReportService.manufacturingExpense(yearOf(p, dateTo));
            case "gl/admin-expense" -> (pg, sz) -> glReportService.adminExpense(yearOf(p, dateTo));
            case "gl/sales-expense" -> (pg, sz) -> glReportService.salesExpense(yearOf(p, dateTo));
            case "gl/operating-pl" -> (pg, sz) -> glReportService.operatingPl(yearOf(p, dateTo), monthOf(p, dateTo));
            // C5 固定资产/长期待摊清单
            case "fa/depreciation-schedule" -> (pg, sz) -> fixedAssetService.depreciationSchedule();
            case "fa/amortization-schedule" -> (pg, sz) -> fixedAssetService.amortizationSchedule();
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报表: " + report);
        };
        return paginateAll(loader);
    }

    /**
     * 只有五类 maker 归属单据的报表可在受限范围内导出；其余公司级及未来新增类型
     * 默认 fail-closed，必须具有完整财务可见性。
     */
    private static boolean requiresCompanyWideExportAccess(String report) {
        if (report == null) return true;
        return switch (report) {
            case "receipt/detail", "receipt/summary",
                 "payment/detail", "payment/summary",
                 "expense/detail", "expense/summary",
                 "income/detail", "income/summary",
                 "fee-offset/detail" -> false;
            default -> true;
        };
    }

    /** 循环分页(size=500)累积全部行；硬上限 2000 页(=百万行)防失控。列取首页 columns 映射为 ExportColumn。 */
    private ExportPayload paginateAll(BiFunction<Integer, Integer, ReportTableResponse> loader) {
        final int size = 500;
        List<Map<String, Object>> all = new ArrayList<>();
        List<ExportColumn> cols = null;
        int page = 1;
        while (page <= 2000) {
            ReportTableResponse r = loader.apply(page, size);
            if (page == 1 && r.total() > settings.readInt("export_max_rows", 100000)) {
                // 大数据量导出内存安全上限：超 10 万行要求收窄筛选/分批，防 OOM。
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出数据超过 10 万行上限，请收窄筛选条件或分批导出");
            }
            if (cols == null && r.columns() != null) {
                cols = r.columns().stream()
                        .map(c -> new ExportColumn(c.key(), c.label(), c.type()))
                        .toList();
            }
            all.addAll(r.rows());
            if (r.rows().size() < size) break;
            if ((long) all.size() >= r.total()) break;
            page++;
        }
        return new ExportPayload(cols == null ? List.of() : cols, all, all.size());
    }

    private static Map<String, String> facetsOfMap(Map<String, String> p) {
        Map<String, String> facets = new LinkedHashMap<>();
        if (p == null) return facets;
        for (Map.Entry<String, String> e : p.entrySet()) {
            if (e.getKey().startsWith("f.") && e.getValue() != null && !e.getValue().isBlank()) {
                facets.put(e.getKey().substring(2), e.getValue());
            }
        }
        return facets;
    }

    private static UUID parseUuid(String s) { return (s == null || s.isBlank()) ? null : UUID.fromString(s); }
    private static Short parseShort(String s) { return (s == null || s.isBlank()) ? null : Short.valueOf(s); }
    private static LocalDate parseDate(String s) { return (s == null || s.isBlank()) ? null : LocalDate.parse(s); }
    private static Boolean parseBool(String s) { return (s == null || s.isBlank()) ? null : Boolean.valueOf(s); }
    private static BigDecimal parseBigDecimal(String s) { return (s == null || s.isBlank()) ? null : new BigDecimal(s); }
    private static int yearOf(Map<String, String> p, LocalDate dateTo) {
        String y = p == null ? null : p.get("year");
        if (y != null && !y.isBlank()) return Integer.parseInt(y);
        return (dateTo != null ? dateTo : BusinessTime.today()).getYear();
    }
    private static int monthOf(Map<String, String> p, LocalDate dateTo) {
        String m = p == null ? null : p.get("month");
        if (m != null && !m.isBlank()) return Integer.parseInt(m);
        return (dateTo != null ? dateTo : BusinessTime.today()).getMonthValue();
    }
    private static int parseIntOrZero(String s) {
        if (s == null || s.isBlank()) return 0;
        try { return Integer.parseInt(s.trim()); } catch (NumberFormatException e) { return 0; }
    }

    // ======================== 内部结构 ========================

    /** 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型。 */
    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {}

    /** WHERE 构造器：base + 若干 AND 子句（带参数）。与销售/采购同型。 */
    static final class WhereBuilder {
        private final String base;
        private final List<Clause> clauses = new ArrayList<>();

        WhereBuilder(String base) { this.base = base; }

        void add(String fragment, String param, Object val) { clauses.add(new Clause(fragment, param, val)); }

        Built build(List<Clause> extra) {
            StringBuilder sb = new StringBuilder(base);
            Map<String, Object> params = new LinkedHashMap<>();
            List<Clause> all = new ArrayList<>(clauses);
            if (extra != null) all.addAll(extra);
            for (Clause c : all) {
                if (c.fragment == null || c.fragment.isEmpty()) {
                    if (c.param != null) params.put(c.param, c.val);
                    continue;
                }
                sb.append(" AND ").append(c.fragment);
                if (c.param != null) params.put(c.param, c.val);
            }
            return new Built(sb.toString(), params);
        }

        record Clause(String fragment, String param, Object val) {}
        record Built(String sql, Map<String, Object> params) {}
    }
}
