package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

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
 * JOIN 范式 {@code em.legacy_id=t.*_legacy_id OR em.id=t.*_id}（四模块共用融合键）。
 *
 * <p>_null 参数类型坑_：可选过滤一律 {@code CAST(:param AS 类型) IS NULL OR ...}（见 MEMORY）。
 *
 * <p>明细表：一行=单里一样货品/一笔（同单号可重复）；汇总表：一行=一整张单（单号唯一）。
 */
@Service
@RequiredArgsConstructor
public class FinanceReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;

    // ======================== 通用执行器（镜像销售/采购） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse execute(List<ReportColumn> columns, String dataSelect, String fromJoin,
                                       WhereBuilder mainWhere, String orderBy, List<FacetSpec> specs,
                                       Map<String, String> activeFacets, int page, int size) {
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

        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql()
                + " ORDER BY " + orderBy + " LIMIT :__limit OFFSET :__offset");
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

        return new ReportTableResponse(columns, items, facets, safePage, safeSize, total, totalPages);
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
        List<ReportColumn> cols = List.of(
                ReportColumn.text("partyName", "往来单位", 220),
                ReportColumn.text("partyType", "类型", 80),
                ReportColumn.money("receivable", "应收金额"),
                ReportColumn.money("payable", "应付金额"),
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
            union.append("SELECT c.name AS partyName, '客户' AS partyType, COALESCE(ar.bal,0) AS receivable, 0 AS payable, "
                    + "COALESCE(c.phone,'') AS phone, COALESCE(c.address,'') AS address FROM clients c "
                    + "LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal FROM ar_ap_ledger "
                    + "WHERE direction='AR' AND is_deleted=false AND status=1"
                    + dateClause("bill_date") + " GROUP BY client_id) ar ON ar.client_id=c.id "
                    + "WHERE COALESCE(c.is_deleted,false)=false" + clientCatFilter);
            if (showSupplier) union.append(" UNION ALL ");
        }
        if (showSupplier) {
            union.append("SELECT s.name AS partyName, '供应商' AS partyType, 0 AS receivable, COALESCE(ap.bal,0) AS payable, "
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
                + (keyword == null || keyword.isBlank() ? " TRUE" : " LOWER(partyName) LIKE LOWER(:kw)"));
        // 包成一个子查询，便于 count + 分页
        String dataSelect = "SELECT partyName, partyType, receivable, payable, phone, address FROM ("
                + union + ") z";
        String fromJoin = "";
        if (keyword != null && !keyword.isBlank()) w.add("", "kw", "%" + keyword.toLowerCase() + "%");
        // arApOverview 用独立查询（带 category 递归 CTE 参数），不走通用 execute 的 facet；这里手写计数+分页
        return executeOverview(cols, dataSelect, fromJoin, w, dateFrom, dateTo, keyword, categoryId,
                onlyClient || onlySupplier ? categoryId : null, page, size);
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
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
    }

    /** A/C 应收/应付明细（ar_ap_ledger，direction=AR 给 A / AP 给 C）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse arApDetail(String direction, String billNo, UUID partyId, Boolean settled,
                                          LocalDate dateFrom, LocalDate dateTo, String keyword,
                                          Map<String, String> facets, int page, int size) {
        String dir = normalizeDirection(direction);
        boolean isAR = "AR".equals(dir);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", isAR ? "立帐单号" : "立帐单号", 150),
                ReportColumn.text("partyName", isAR ? "客户名称" : "供应商", 180),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.date("dueDate", isAR ? "收款限期" : "付款限期"),
                ReportColumn.text("settlementStyle", "结帐方式", 90),
                ReportColumn.bool("settled", isAR ? "是否已收款" : "是否已付款"),
                ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.number("rate", "汇率"),
                ReportColumn.money("amount", isAR ? "应收帐款" : "应付帐款"),
                ReportColumn.text("remark", "摘要", 160));
        String dataSelect = """
                SELECT l.bill_no AS "billNo", COALESCE(c.name, s.name) AS "partyName", l.bill_date AS "billDate",
                       l.due_date AS "dueDate", CAST(l.settlement_style_legacy AS text) AS "settlementStyle",
                       l.is_settled AS "settled", cur.code AS "currencyCode", l.exchange_rate AS "rate",
                       l.amount_original_local AS "amount", l.remark AS "remark"
                """;
        String fromJoin = """
                FROM ar_ap_ledger l
                LEFT JOIN clients c ON c.id=l.client_id
                LEFT JOIN suppliers s ON s.id=l.supplier_id
                LEFT JOIN currencies cur ON cur.id=l.currency_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(l.is_deleted,false)=false AND l.direction=:dir AND l.status=1");
        w.add("", "dir", dir);
        if (billNo != null && !billNo.isBlank()) w.add("l.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (partyId != null) w.add(isAR ? "l.client_id=:pid" : "l.supplier_id=:pid", "pid", partyId);
        if (settled != null) w.add("l.is_settled=:settled", "settled", settled);
        if (dateFrom != null) w.add("l.bill_date>=:dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("l.bill_date<=:dateTo", "dateTo", dateTo);
        if (keyword != null && !keyword.isBlank())
            w.add("(LOWER(l.bill_no) LIKE LOWER(:kw) OR LOWER(COALESCE(c.name,s.name)) LIKE LOWER(:kw))", "kw", "%" + keyword.toLowerCase() + "%");
        List<FacetSpec> specs = List.of(
                new FacetSpec("settled", "l.is_settled AS v, CASE WHEN l.is_settled THEN '已收/付' ELSE '未收/付' END AS lbl", "l.is_settled", "l.is_settled", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "l.bill_date DESC, l.bill_no", specs, facets, page, size);
    }

    /** B/D 应收/应付汇总（按往来单位 GROUP BY，含期初/本期立帐/核销/期末余额）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse arApSummary(String direction, LocalDate dateFrom, LocalDate dateTo, String keyword,
                                          Map<String, String> facets, int page, int size) {
        String dir = normalizeDirection(direction);
        LocalDate from = dateFrom != null ? dateFrom : LocalDate.of(2010, 1, 1);
        LocalDate to = dateTo != null ? dateTo : LocalDate.now();
        return "AR".equals(dir)
                ? receivableSummary(keyword, from, to, page, size)
                : payableSummary(keyword, from, to, facets, page, size);
    }

    /** B 应收款汇总（按客户；期初/发货/回款/退货/期末 用「立帐 − 收款」时序一致口径，保证 期初+发货+退货−回款=期末）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receivableSummary(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("partyCode", "客户编号", 110),
                ReportColumn.text("partyName", "客户简称", 160),
                ReportColumn.text("partyFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100),
                ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100),
                ReportColumn.text("district", "所属地区", 110),
                ReportColumn.money("creditFloor", "铺底额"),
                ReportColumn.money("prevBalance", "上月余额"),
                ReportColumn.money("shippedAmount", "发货金额"),
                ReportColumn.money("receivedAmount", "回款金额"),
                ReportColumn.money("returnAmount", "退货金额"),
                ReportColumn.money("offsetAmount", "货款冲销"),
                ReportColumn.money("balance", "应收余额"),
                ReportColumn.money("overFloor", "超出铺底额"),
                ReportColumn.money("materialAmount", "物料金额"));
        // 立帐取 ar_ap_ledger.amount_original_local（按 bill_date 归期），收款取 finance_receipts.amount_local
        // （按 bill_date 归期）。**不用累计 amount_settled**——它无法按期切分，会让 期初/期末 与 回款 口径不一致。
        // 退货（SALES_RETURN）amount_original_local 为负，自动冲减。恒等式：期初+发货+退货−回款=期末。
        String core = """
                WITH posting AS (
                    SELECT client_id,
                        SUM(CASE WHEN bill_date < :from THEN amount_original_local ELSE 0 END) AS prior_posted,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to AND source_doc_type='SALES_SHIPMENT' THEN amount_original_local ELSE 0 END) AS shipped,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to AND source_doc_type='SALES_RETURN' THEN amount_original_local ELSE 0 END) AS returned,
                        SUM(CASE WHEN bill_date <= :to THEN amount_original_local ELSE 0 END) AS total_posted
                    FROM ar_ap_ledger WHERE is_deleted=false AND status=1 AND direction='AR' AND client_id IS NOT NULL
                    GROUP BY client_id
                ), coll AS (
                    SELECT client_id,
                        SUM(CASE WHEN bill_date < :from THEN amount_local ELSE 0 END) AS prior_coll,
                        SUM(CASE WHEN bill_date BETWEEN :from AND :to THEN amount_local ELSE 0 END) AS period_coll,
                        SUM(amount_local) AS total_coll
                    FROM finance_receipts WHERE COALESCE(is_deleted,false)=false AND status=1 AND client_id IS NOT NULL
                    GROUP BY client_id
                )
                SELECT c.code AS "partyCode", c.name AS "partyName", c.full_name AS "partyFull",
                    COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director",
                    COALESCE(c.region,'') AS "region", COALESCE(c.place_id,'') AS "district",
                    NULL AS "creditFloor",
                    (COALESCE(p.prior_posted,0) - COALESCE(co.prior_coll,0)) AS "prevBalance",
                    COALESCE(p.shipped,0) AS "shippedAmount",
                    COALESCE(co.period_coll,0) AS "receivedAmount",
                    COALESCE(p.returned,0) AS "returnAmount",
                    COALESCE(co.period_coll,0) AS "offsetAmount",
                    (COALESCE(p.total_posted,0) - COALESCE(co.total_coll,0)) AS "balance",
                    NULL AS "overFloor", NULL AS "materialAmount"
                FROM clients c
                JOIN posting p ON p.client_id=c.id
                LEFT JOIN coll co ON co.client_id=c.id
                LEFT JOIN client_director_v d ON d.client_id=c.id
                LEFT JOIN employees em_sel ON em_sel.legacy_id=CAST(NULLIF(REGEXP_REPLACE(COALESCE(c.emp_id,''),'[^0-9]','','g'),'') AS int)
                """;
        return executeRawPaged(cols, core, "c.name", keyword, from, to, page, size);
    }

    /** D 应付款汇总（按立帐单号一行一单：立帐单号/供应商/开单日期/币别/汇率/应付帐款/已付金额）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse payableSummary(String keyword, LocalDate from, LocalDate to,
                                              Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "立帐单号", 150),
                ReportColumn.text("supplierName", "供应商", 180),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.number("rate", "汇率"),
                ReportColumn.money("payable", "应付帐款"),
                ReportColumn.money("paid", "已付金额"));
        String dataSelect = """
                SELECT l.bill_no AS "billNo", s.name AS "supplierName", l.bill_date AS "billDate",
                       cur.code AS "currencyCode", l.exchange_rate AS "rate",
                       l.amount_original_local AS "payable", l.amount_settled AS "paid"
                """;
        String fromJoin = """
                FROM ar_ap_ledger l
                LEFT JOIN suppliers s ON s.id=l.supplier_id
                LEFT JOIN currencies cur ON cur.id=l.currency_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(l.is_deleted,false)=false AND l.status=1 AND l.direction='AP'");
        if (keyword != null && !keyword.isBlank())
            w.add("(LOWER(l.bill_no) LIKE LOWER(:kw) OR LOWER(COALESCE(s.name,'')) LIKE LOWER(:kw))", "kw", "%" + keyword.toLowerCase() + "%");
        if (from != null) w.add("l.bill_date>=:dateFrom", "dateFrom", from);
        if (to != null) w.add("l.bill_date<=:dateTo", "dateTo", to);
        return execute(cols, dataSelect, fromJoin, w, "l.bill_date DESC, l.bill_no", List.of(), facets, page, size);
    }

    /** 原生 SQL 分页执行器（CTE/聚合报表用，如 B 应收汇总）。SQL 含 :from/:to[/:kw] 参数。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeRawPaged(List<ReportColumn> cols, String coreSql, String orderBy,
                                                String keyword, LocalDate from, LocalDate to, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        String where = "WHERE TRUE";
        if (keyword != null && !keyword.isBlank()) {
            where = "WHERE (LOWER(COALESCE(c.name,'')) LIKE LOWER(:kw) OR LOWER(COALESCE(c.code,'')) LIKE LOWER(:kw))";
        }
        var dq = em.createNativeQuery(coreSql + " " + where + " ORDER BY " + orderBy + " LIMIT :__l OFFSET :__o");
        bindRaw(dq, keyword, from, to);
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
        long total = ((Number) cq.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
    }

    private static void bindRaw(jakarta.persistence.Query q, String keyword, LocalDate from, LocalDate to) {
        if (keyword != null && !keyword.isBlank()) q.setParameter("kw", "%" + keyword.toLowerCase() + "%");
        q.setParameter("from", from);
        q.setParameter("to", to);
    }

    // ======================== ② 收付款明细/汇总 E·F / G·H ========================

    /** E 销售收款明细（finance_receipts + clients + client_director_v + accounts + 人员）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receiptDetail(String billNo, UUID clientId, UUID accountId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户名称", 160), ReportColumn.text("clientFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100), ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("district", "所属地区", 110),
                ReportColumn.text("accountName", "收款帐户", 130), ReportColumn.text("departmentName", "部门", 120),
                ReportColumn.money("amountOriginal", "收款总额"),
                ReportColumn.money("uncollected", "未收金额"),
                ReportColumn.money("balance", "本次余额"),
                ReportColumn.money("otherFee", "其它费用金额"),
                ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director", COALESCE(c.region,'') AS "region",
                       COALESCE(c.place_id,'') AS "district", a.name AS "accountName", NULL AS "departmentName",
                       t.amount_original AS "amountOriginal", COALESCE(ar.bal,0) AS "uncollected",
                       (COALESCE(ar.bal,0) - t.amount_local) AS "balance",
                       t.other_fee AS "otherFee", t.remark AS "remark"
                """;
        String fromJoin = """
                FROM finance_receipts t
                LEFT JOIN clients c ON c.id=t.client_id
                LEFT JOIN client_director_v d ON d.client_id=t.client_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN employees em_sel ON em_sel.legacy_id=CAST(NULLIF(REGEXP_REPLACE(COALESCE(c.emp_id,''),'[^0-9]','','g'),'') AS int)
                LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal FROM ar_ap_ledger WHERE direction='AR' AND is_deleted=false AND status=1 GROUP BY client_id) ar ON ar.client_id=t.client_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false");
        addFinanceDocFilters(w, billNo, clientId, accountId, status, dateFrom, dateTo, keyword, "t.bill_no", "t.bill_date", "c.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size);
    }

    /** F 销售收款汇总（按客户 GROUP BY）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse receiptSummary(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientCode", "客户编号", 110), ReportColumn.text("clientName", "客户名称", 160),
                ReportColumn.text("clientFull", "客户全称", 200), ReportColumn.text("address", "客户地址", 200),
                ReportColumn.text("district", "所属地区", 110), ReportColumn.money("amountTotal", "收款总额"),
                ReportColumn.money("bankFee", "手续费"));
        String dataSelect = """
                SELECT c.code AS "clientCode", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(c.address,'') AS "address", COALESCE(c.place_id,'') AS "district",
                       SUM(t.amount_original) AS "amountTotal", SUM(t.bank_fee) AS "bankFee"
                """;
        String fromJoin = " FROM finance_receipts t JOIN clients c ON c.id=t.client_id ";
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false");
        addFinanceDocFilters(w, billNo, clientId, null, status, dateFrom, dateTo, keyword, "t.bill_no", "t.bill_date", "c.name");
        return executeGrouped(cols, dataSelect, fromJoin, w, "c.name", "c.id,c.code,c.name,c.full_name,c.address,c.place_id", page, size);
    }

    /** G 采购付款明细（finance_payments + suppliers + accounts + 人员）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse paymentDetail(String billNo, UUID supplierId, UUID accountId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 180), ReportColumn.text("operatorName", "付款人", 100),
                ReportColumn.text("accountName", "付款帐户", 130), ReportColumn.money("amountOriginal", "实付金额(外)"),
                ReportColumn.money("amountTotal", "付款总额"), ReportColumn.money("amountLocal", "实付金额"),
                ReportColumn.text("incomeItem", "收入项目名称", 130), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("handlerName", "经手人", 100), ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", s.name AS "supplierName",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", t.amount_original AS "amountOriginal", t.amount_original AS "amountTotal",
                       t.amount_local AS "amountLocal", NULL AS "incomeItem", ca.name AS "counterpartAccount",
                       COALESCE(em_op.full_name, t.operator_name, '') AS "handlerName", t.remark AS "remark"
                """;
        String fromJoin = """
                FROM finance_payments t
                LEFT JOIN suppliers s ON s.id=t.supplier_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=t.counterpart_account_id
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false");
        addFinanceDocFilters(w, billNo, supplierId, accountId, status, dateFrom, dateTo, keyword, "t.bill_no", "t.bill_date", "s.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size);
    }

    /** H 采购付款汇总（一行一付款单 + 关联 AP 立帐单/已付/未付/本次付款/本次余额）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse paymentSummary(String billNo, UUID supplierId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 180), ReportColumn.text("operatorName", "付款人", 100),
                ReportColumn.text("payStyle", "付款方式", 100), ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.number("rate", "汇率"), ReportColumn.money("amountTotal", "付款总额"),
                ReportColumn.money("amountLocal", "实付金额"), ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100), ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("ledgerBillNo", "立帐单号", 150), ReportColumn.date("tradeDate", "交易日期"),
                ReportColumn.money("paid", "已付金额"), ReportColumn.money("unpaid", "未付金额"),
                ReportColumn.money("thisPay", "本次付款"), ReportColumn.money("thisBalance", "本次余额"),
                ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("counterpartAccount", "对方账户", 140), ReportColumn.text("handlerName", "经手人", 100));
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
                       COALESCE(em_op.full_name, t.operator_name,'') AS "handlerName"
                """;
        String fromJoin = """
                FROM finance_payments t
                LEFT JOIN suppliers s ON s.id=t.supplier_id
                LEFT JOIN currencies cur ON cur.id=t.currency_id
                LEFT JOIN accounts ca ON ca.id=t.counterpart_account_id
                LEFT JOIN ar_ap_ledger ap ON ap.source_doc_id=t.id AND ap.source_doc_type='DIRECT_PAYMENT' AND ap.is_deleted=false
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                LEFT JOIN employees em_mk ON em_mk.legacy_id=t.maker_legacy_id OR em_mk.id=t.maker_id
                LEFT JOIN employees em_ap ON em_ap.legacy_id=t.approver_legacy_id OR em_ap.id=t.approver_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false");
        addFinanceDocFilters(w, billNo, supplierId, null, status, dateFrom, dateTo, keyword, "t.bill_no", "t.bill_date", "s.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size);
    }

    // ======================== ③ 费用/收入明细/汇总 M·N / O·P + V ========================

    /** M 一般费用明细（finance_expense_items JOIN finance_expenses，按费用项目/部门分摊）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse expenseDetail(String billNo, UUID accountId, UUID departmentId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String keyword,
                                             Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "付款人", 100), ReportColumn.text("accountName", "付款帐户", 130),
                ReportColumn.text("currencyCode", "币别", 80), ReportColumn.money("amountTotal", "付款总额"),
                ReportColumn.money("amountLocal", "实付金额"), ReportColumn.text("styleName", "费用项目名称", 130),
                ReportColumn.number("qty", "数量"), ReportColumn.money("price", "单价"),
                ReportColumn.money("lineAmount", "支出金额"), ReportColumn.text("counterpartName", "对方", 120),
                ReportColumn.text("departmentName", "部门", 120), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("remark", "备注", 160), ReportColumn.text("summary", "摘要", 160),
                ReportColumn.number("lineNo", "序号"));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", cur.code AS "currencyCode", t.amount_original AS "amountTotal", t.amount_local AS "amountLocal",
                       ps.name AS "styleName", i.qty AS "qty", i.price AS "price", i.amount_local AS "lineAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", d.name AS "departmentName",
                       ca.name AS "counterpartAccount", t.remark AS "remark", i.summary AS "summary", i.line_no AS "lineNo"
                """;
        String fromJoin = """
                FROM finance_expense_items i
                JOIN finance_expenses t ON t.id=i.expense_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN currencies cur ON cur.id=t.currency_id
                LEFT JOIN payment_styles ps ON ps.id=i.expense_style_id
                LEFT JOIN departments d ON d.id=i.department_id
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false");
        addFinanceItemFilters(w, billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size);
    }

    /** N 一般费用汇总（按 单号×部门×费用项目 GROUP BY items）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse expenseSummary(String billNo, UUID departmentId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "付款人", 100), ReportColumn.text("accountName", "付款帐户", 130),
                ReportColumn.money("amountLocal", "实付金额"), ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100), ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("styleName", "费用项目名称", 130), ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"), ReportColumn.money("lineAmount", "支出金额"),
                ReportColumn.text("counterpartName", "对方", 120), ReportColumn.text("counterpartAccount", "对方账户", 140),
                ReportColumn.text("summary", "摘要", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName", a.name AS "accountName",
                       t.amount_local AS "amountLocal", COALESCE(em_mk.full_name, t.maker_name,'') AS "makerName",
                       COALESCE(em_ap.full_name, t.approver_name,'') AS "approverName", t.remark AS "remark",
                       ps.name AS "styleName", i.qty AS "qty", i.price AS "price", i.amount_local AS "lineAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount", i.summary AS "summary"
                """;
        String fromJoin = """
                FROM finance_expense_items i
                JOIN finance_expenses t ON t.id=i.expense_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.expense_style_id
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                LEFT JOIN employees em_mk ON em_mk.legacy_id=t.maker_legacy_id OR em_mk.id=t.maker_id
                LEFT JOIN employees em_ap ON em_ap.legacy_id=t.approver_legacy_id OR em_ap.id=t.approver_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false");
        addFinanceItemFilters(w, billNo, null, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size);
    }

    /** O 其它收入明细。 */
    @Transactional(readOnly = true)
    public ReportTableResponse incomeDetail(String billNo, UUID accountId, UUID departmentId, Short status,
                                            LocalDate dateFrom, LocalDate dateTo, String keyword,
                                            Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "收款人", 100), ReportColumn.text("accountName", "收款帐户", 130),
                ReportColumn.money("amountTotal", "收款总额"), ReportColumn.text("styleName", "收入项目名称", 130),
                ReportColumn.text("counterpartName", "对方", 120), ReportColumn.text("counterpartAccount", "对方账号", 140),
                ReportColumn.text("summary", "摘要", 160), ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name, '') ||
                         CASE WHEN COALESCE(em_op.legacy_category,'') <> '' THEN ' ('||em_op.legacy_category||')' ELSE '' END AS "operatorName",
                       a.name AS "accountName", t.amount_original AS "amountTotal", ps.name AS "styleName",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount",
                       i.summary AS "summary", t.remark AS "remark"
                """;
        String fromJoin = """
                FROM finance_other_income_items i
                JOIN finance_other_incomes t ON t.id=i.income_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.income_style_id
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false");
        addFinanceItemFilters(w, billNo, accountId, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size);
    }

    /** P 其它收入汇总。 */
    @Transactional(readOnly = true)
    public ReportTableResponse incomeSummary(String billNo, UUID departmentId, Short status, LocalDate dateFrom,
                                             LocalDate dateTo, String keyword, Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("operatorName", "收款人", 100), ReportColumn.text("accountName", "收款帐户", 130),
                ReportColumn.money("amountTotal", "收款总额"), ReportColumn.money("amountLocal", "实付金额"),
                ReportColumn.text("makerName", "制单员", 100), ReportColumn.text("approverName", "审核员", 100),
                ReportColumn.text("remark", "备注", 160), ReportColumn.text("styleName", "收入项目名称", 130),
                ReportColumn.money("incomeAmount", "收入金额"), ReportColumn.text("counterpartName", "对方", 120),
                ReportColumn.text("counterpartAccount", "对方账户", 140), ReportColumn.text("summary", "摘要", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName", a.name AS "accountName",
                       t.amount_original AS "amountTotal", t.amount_local AS "amountLocal",
                       COALESCE(em_mk.full_name, t.maker_name,'') AS "makerName",
                       COALESCE(em_ap.full_name, t.approver_name,'') AS "approverName", t.remark AS "remark",
                       ps.name AS "styleName", i.amount_local AS "incomeAmount",
                       COALESCE(i.counterpart_name,'') AS "counterpartName", ca.name AS "counterpartAccount", i.summary AS "summary"
                """;
        String fromJoin = """
                FROM finance_other_income_items i
                JOIN finance_other_incomes t ON t.id=i.income_id
                LEFT JOIN accounts a ON a.id=t.account_id
                LEFT JOIN accounts ca ON ca.id=i.counterpart_account_id
                LEFT JOIN payment_styles ps ON ps.id=i.income_style_id
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                LEFT JOIN employees em_mk ON em_mk.legacy_id=t.maker_legacy_id OR em_mk.id=t.maker_id
                LEFT JOIN employees em_ap ON em_ap.legacy_id=t.approver_legacy_id OR em_ap.id=t.approver_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false");
        addFinanceItemFilters(w, billNo, null, departmentId, status, dateFrom, dateTo, keyword, "t.bill_no", "i.bill_date");
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, t.bill_no, i.line_no NULLS LAST", List.of(), facets, page, size);
    }

    /** V 费用冲销明细（销售收款侧带 AR 核销 + 其它费用；按用户列规格，覆盖旧"同M"注释）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse feeOffsetDetail(String billNo, UUID clientId, UUID accountId, Short status,
                                               LocalDate dateFrom, LocalDate dateTo, String keyword,
                                               Map<String, String> facets, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户名称", 160), ReportColumn.text("clientFull", "客户全称", 200),
                ReportColumn.text("sellerName", "业务员", 100), ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("district", "所属地区", 110),
                ReportColumn.text("operatorName", "收款人", 100), ReportColumn.money("uncollected", "未收金额"),
                ReportColumn.money("thisReceipt", "本次收款"), ReportColumn.money("balance", "本次余额"),
                ReportColumn.money("otherFee", "其它费用金额"), ReportColumn.text("remark", "备注", 160));
        String dataSelect = """
                SELECT t.bill_no AS "billNo", t.bill_date AS "billDate", c.name AS "clientName", c.full_name AS "clientFull",
                       COALESCE(em_sel.full_name,'') AS "sellerName", d.director AS "director", COALESCE(c.region,'') AS "region",
                       COALESCE(c.place_id,'') AS "district",
                       COALESCE(em_op.full_name, t.operator_name,'') AS "operatorName",
                       COALESCE(ar.bal,0) AS "uncollected", t.amount_local AS "thisReceipt", (COALESCE(ar.bal,0) - t.amount_local) AS "balance",
                       t.other_fee AS "otherFee", t.remark AS "remark"
                """;
        String fromJoin = """
                FROM finance_receipts t
                LEFT JOIN clients c ON c.id=t.client_id
                LEFT JOIN client_director_v d ON d.client_id=t.client_id
                LEFT JOIN employees em_sel ON em_sel.legacy_id=CAST(NULLIF(REGEXP_REPLACE(COALESCE(c.emp_id,''),'[^0-9]','','g'),'') AS int)
                LEFT JOIN employees em_op ON em_op.legacy_id=t.operator_legacy_id OR em_op.id=t.operator_id
                LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal FROM ar_ap_ledger WHERE direction='AR' AND is_deleted=false AND status=1 GROUP BY client_id) ar ON ar.client_id=t.client_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(t.is_deleted,false)=false");
        addFinanceDocFilters(w, billNo, clientId, accountId, status, dateFrom, dateTo, keyword, "t.bill_no", "t.bill_date", "c.name");
        return execute(cols, dataSelect, fromJoin, w, "t.bill_date DESC, t.bill_no", List.of(), facets, page, size);
    }

    // ======================== ④ 往来对帐单 I·J·K·L / X（滚动余额，源=头表+台账） ========================

    /** I/K 单客户/供应商流水对帐（AR/AP 立帐 + 收款/付款头表合并，滚动余额；外/本/汇率列）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyStatementFlow(UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo,
                                                  int page, int size) {
        if (partyId == null) return empty(List.of(
                ReportColumn.date("billDate", "开单日期"), ReportColumn.text("refNo", "关联单号", 150),
                ReportColumn.money("salesOriginal", "销售金额(外)"), ReportColumn.number("salesRate", "销售汇率"),
                ReportColumn.money("salesLocal", "销售金额(本)"), ReportColumn.money("receiptOriginal", "收款金额(外)"),
                ReportColumn.number("receiptRate", "收款汇率"), ReportColumn.money("receiptLocal", "收款金额(本)"),
                ReportColumn.money("balanceOriginal", "应收余额(外)"), ReportColumn.number("balanceRate", "应收汇率"),
                ReportColumn.money("balanceLocal", "应收余额(本)")));
        boolean isAR = "AR".equalsIgnoreCase(side);
        // 立帐行（ar_ap_ledger）+ 收/付款行（finance_receipts/payments 头表）
        String posted = isAR
                ? "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0 AS r_org, 0 AS r_rate, 0 AS r_loc "
                + "FROM ar_ap_ledger l WHERE l.is_deleted=false AND l.direction='AR' AND l.status=1 AND l.client_id=:pid"
                : "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0,0,0 "
                + "FROM ar_ap_ledger l WHERE l.is_deleted=false AND l.direction='AP' AND l.status=1 AND l.supplier_id=:pid";
        String settled = isAR
                ? "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original AS r_org, t.exchange_rate AS r_rate, t.amount_local AS r_loc "
                + "FROM finance_receipts t WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.client_id=:pid"
                : "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original, t.exchange_rate, t.amount_local "
                + "FROM finance_payments t WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.supplier_id=:pid";
        String sql = "SELECT * FROM (" + posted + " UNION ALL " + settled + ") u "
                + "WHERE (CAST(:from AS date) IS NULL OR bill_date>=:from) AND (CAST(:to AS date) IS NULL OR bill_date<=:to) "
                + "ORDER BY bill_date ASC, bill_no ASC";
        return buildRunningBalance(partyStatementFlowCols(isAR), sql, partyId, dateFrom, dateTo, page, size, true);
    }

    private static List<ReportColumn> partyStatementFlowCols(boolean isAR) {
        String pre = isAR ? "销售" : "采购";
        String rec = isAR ? "收款" : "付款";
        String bal = isAR ? "应收" : "应付";
        return List.of(
                ReportColumn.date("billDate", "开单日期"), ReportColumn.text("refNo", "关联单号", 150),
                ReportColumn.money("salesOriginal", pre + "金额(外)"), ReportColumn.number("salesRate", pre + "汇率"),
                ReportColumn.money("salesLocal", pre + "金额(本)"), ReportColumn.money("receiptOriginal", rec + "金额(外)"),
                ReportColumn.number("receiptRate", rec + "汇率"), ReportColumn.money("receiptLocal", rec + "金额(本)"),
                ReportColumn.money("balanceOriginal", bal + "余额(外)"), ReportColumn.number("balanceRate", bal + "汇率"),
                ReportColumn.money("balanceLocal", bal + "余额(本)"));
    }

    /** J/L 单客户/供应商明细对帐（逐行更详细：立帐单号/收付款单号/币别/摘要）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyStatementDetail(UUID partyId, String side, LocalDate dateFrom, LocalDate dateTo,
                                                    int page, int size) {
        if (partyId == null) return empty(partyStatementFlowCols("AR".equalsIgnoreCase(side)));
        // 复用 flow 的 UNION，扩列 type/currencyCode/remark
        boolean isAR = "AR".equalsIgnoreCase(side);
        String posted = isAR
                ? "SELECT l.bill_date, l.bill_no, l.amount_original AS org, l.exchange_rate AS rate, l.amount_original_local AS loc, 0 AS r_org, 0 AS r_rate, 0 AS r_loc, '立帐' AS typ, cur.code AS cur, l.remark "
                + "FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id WHERE l.is_deleted=false AND l.direction='AR' AND l.status=1 AND l.client_id=:pid"
                : "SELECT l.bill_date, l.bill_no, l.amount_original, l.exchange_rate, l.amount_original_local, 0,0,0, '立帐', cur.code, l.remark "
                + "FROM ar_ap_ledger l LEFT JOIN currencies cur ON cur.id=l.currency_id WHERE l.is_deleted=false AND l.direction='AP' AND l.status=1 AND l.supplier_id=:pid";
        String settled = isAR
                ? "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original, t.exchange_rate, t.amount_local, '收款', cur.code, t.remark "
                + "FROM finance_receipts t LEFT JOIN currencies cur ON cur.id=t.currency_id WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.client_id=:pid"
                : "SELECT t.bill_date, t.bill_no, 0,0,0, t.amount_original, t.exchange_rate, t.amount_local, '付款', cur.code, t.remark "
                + "FROM finance_payments t LEFT JOIN currencies cur ON cur.id=t.currency_id WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t.supplier_id=:pid";
        String sql = "SELECT * FROM (" + posted + " UNION ALL " + settled + ") u "
                + "WHERE (CAST(:from AS date) IS NULL OR bill_date>=:from) AND (CAST(:to AS date) IS NULL OR bill_date<=:to) "
                + "ORDER BY bill_date ASC, bill_no ASC";
        List<ReportColumn> cols = new ArrayList<>(partyStatementFlowCols(isAR));
        cols.add(2, ReportColumn.text("type", "类型", 80));
        cols.add(3, ReportColumn.text("currencyCode", "币别", 80));
        cols.add(ReportColumn.text("remark", "摘要", 160));
        return buildRunningBalance(cols, sql, partyId, dateFrom, dateTo, page, size, false);
    }

    /** X 客户/供应商年度对帐单（按月：期初/立帐(发货)/收款(回款)/退货/期末；一年 12 行 + 汇总）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse partyAnnualStatement(UUID partyId, String side, int year,
                                                    int page, int size) {
        boolean isAR = "AR".equalsIgnoreCase(side);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("ym", "月份", 100),
                ReportColumn.money("prevBalance", "期初" + (isAR ? "应收" : "应付")),
                ReportColumn.money("posted", isAR ? "发货金额" : "收货金额"),
                ReportColumn.money("settled", isAR ? "回款金额" : "付款金额"),
                ReportColumn.money("returned", "退货金额"),
                ReportColumn.money("balance", "期末" + (isAR ? "应收" : "应付")));
        if (partyId == null || year <= 0) return empty(cols);
        LocalDate yearStart = LocalDate.of(year, 1, 1);
        LocalDate yearEnd = LocalDate.of(year, 12, 31);
        String partyCol = isAR ? "client_id" : "supplier_id";
        String dirLit = isAR ? "'AR'" : "'AP'";
        String settledTbl = isAR ? "finance_receipts" : "finance_payments";
        // 按月：期初=该月初前累计余额；期末=下月初前累计余额（滚动）；posted/settled 为当月发生额。
        // returned 简化为 0（退货已在 ar_ap_ledger SALES_RETURN/PURCHASE_RETURN 体现为负 posted）。
        String sql = "WITH party_ledger AS ("
                + " SELECT bill_date, amount_original_local AS posted, 0 AS settled FROM ar_ap_ledger l"
                + " WHERE l.is_deleted=false AND l.direction=" + dirLit + " AND l.status=1 AND l." + partyCol + "=:pid"
                + " UNION ALL"
                + " SELECT t.bill_date, 0, t.amount_local FROM " + settledTbl + " t"
                + " WHERE COALESCE(t.is_deleted,false)=false AND t.status=1 AND t." + partyCol + "=:pid"
                + "), monthly AS ("
                + " SELECT date_trunc('month', pl.bill_date) AS ms, to_char(date_trunc('month', pl.bill_date),'YYYY-MM') AS ym,"
                + " COALESCE(SUM(pl.posted),0) AS posted, COALESCE(SUM(pl.settled),0) AS settled"
                + " FROM party_ledger pl WHERE pl.bill_date BETWEEN :ys AND :ye GROUP BY 1, 2)"
                + " SELECT m.ym,"
                + " COALESCE((SELECT SUM(p2.posted-p2.settled) FROM party_ledger p2 WHERE p2.bill_date < m.ms),0) AS prevBalance,"
                + " m.posted, m.settled, 0 AS returned,"
                + " COALESCE((SELECT SUM(p3.posted-p3.settled) FROM party_ledger p3 WHERE p3.bill_date < m.ms + INTERVAL '1 month'),0) AS balance"
                + " FROM monthly m ORDER BY m.ym";
        return executeRawGrouped(cols, sql, partyId, yearStart, yearEnd, page, size);
    }

    // ======================== ⑤ 账户流水 S / 银行存取 Q·R ========================

    /** S 帐户进出流水帐（finance_reconciliations 滚动余额，必填 accountId）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse accountStatement(UUID accountId, LocalDate dateFrom, LocalDate dateTo,
                                                String keyword, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "日期"), ReportColumn.text("billNo", "单号", 140),
                ReportColumn.text("checkNo", "支票号", 120), ReportColumn.text("summary", "摘要", 160),
                ReportColumn.text("counterpartName", "对方单位", 160), ReportColumn.text("source", "支票来源", 120),
                ReportColumn.date("settledDate", "核销日期"), ReportColumn.money("inAmount", "收款金额"),
                ReportColumn.money("outAmount", "支出金额"), ReportColumn.money("balance", "余额"));
        if (accountId == null) return empty(cols);
        String sql = "SELECT r.bill_date AS billDate, r.bill_no AS billNo, COALESCE(r.check_no,'') AS checkNo, "
                + "COALESCE(r.remark,'') AS summary, COALESCE(r.counterpart_name,'') AS counterpartName, "
                + "COALESCE(r.source_remark,'') AS source, r.settled_date AS settledDate, "
                + "r.in_amount AS inAmount, r.out_amount AS outAmount FROM finance_reconciliations r "
                + "WHERE COALESCE(r.is_deleted,false)=false AND r.account_id=:aid "
                + "AND (CAST(:from AS date) IS NULL OR r.bill_date>=:from) AND (CAST(:to AS date) IS NULL OR r.bill_date<=:to) "
                + "AND (CAST(:kw AS text) IS NULL OR LOWER(COALESCE(r.bill_no,'')||' '||COALESCE(r.counterpart_name,'')||' '||COALESCE(r.remark,'')) LIKE LOWER(:kw)) "
                + "ORDER BY r.bill_date ASC, r.bill_no ASC";
        return buildAccountRunning(cols, sql, accountId, dateFrom, dateTo, keyword, page, size);
    }

    /** Q 银行存取明细 / R 汇总（M_Bank 0 行，返回空结构）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse bankReport(String view) {
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

    // ======================== 通用辅助 ========================

    private static void addFinanceDocFilters(WhereBuilder w, String billNo, UUID partyId, UUID accountId,
                                             Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                             String billNoCol, String dateCol, String partyNameCol) {
        if (billNo != null && !billNo.isBlank()) w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        if (partyId != null) w.add("t.client_id=:pid OR t.supplier_id=:pid", "pid", partyId);
        if (accountId != null) w.add("t.account_id=:accountId", "accountId", accountId);
        if (status != null) w.add("t.status=:status", "status", status);
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
        if (status != null) w.add("t.status=:status", "status", status);
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

    /** 滚动余额：全量排序取，Java 累加 running balance，再手动分页（balance 在分页前算完整）。
     *  金额列统一在索引 [2..7]（org/rate/loc/r_org/r_rate/r_loc）；detail 额外 [8]type [9]cur [10]remark。 */
    @Transactional(readOnly = true)
    private ReportTableResponse buildRunningBalance(List<ReportColumn> cols, String sql, UUID pid,
                                                    LocalDate dateFrom, LocalDate dateTo, int page, int size, boolean simpleCols) {
        var q = em.createNativeQuery(sql).setParameter("pid", pid).setParameter("from", dateFrom).setParameter("to", dateTo);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        BigDecimal runOrg = BigDecimal.ZERO, runLoc = BigDecimal.ZERO;
        List<Map<String, Object>> all = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            BigDecimal org = num(r[2]); BigDecimal rate = numOrNull(r[3]); BigDecimal loc = num(r[4]);
            BigDecimal rOrg = num(r[5]); BigDecimal rRate = numOrNull(r[6]); BigDecimal rLoc = num(r[7]);
            runOrg = runOrg.add(org).subtract(rOrg);
            runLoc = runLoc.add(loc).subtract(rLoc);
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("billDate", norm(r[0])); m.put("refNo", norm(r[1]));
            if (!simpleCols) { m.put("type", norm(r[8])); m.put("currencyCode", norm(r[9])); }
            m.put("salesOriginal", norm(org)); m.put("salesRate", norm(rate)); m.put("salesLocal", norm(loc));
            m.put("receiptOriginal", norm(rOrg)); m.put("receiptRate", norm(rRate)); m.put("receiptLocal", norm(rLoc));
            m.put("balanceOriginal", norm(runOrg)); m.put("balanceRate", norm(rate)); m.put("balanceLocal", norm(runLoc));
            if (!simpleCols) { m.put("remark", norm(r[10])); }
            all.add(m);
        }
        return paginate(cols, all, page, size);
    }

    /** 安全 BigDecimal：null→0，BigDecimal/Number→BigDecimal，否则解析字符串。 */
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
        String k = (kw == null || kw.isBlank()) ? null : "%" + kw.toLowerCase() + "%";
        var q = em.createNativeQuery(sql).setParameter("aid", aid).setParameter("from", dateFrom)
                .setParameter("to", dateTo).setParameter("kw", k);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        // 期初余额 = 账户 init_balance + dateFrom 之前的流水净额（保证「余额」跨期连续，不随日期筛选清零）。
        BigDecimal opening = BigDecimal.ZERO;
        var oq = em.createNativeQuery(
                "SELECT COALESCE(a.init_balance,0) + COALESCE((SELECT SUM(r.in_amount - r.out_amount) "
                        + "FROM finance_reconciliations r WHERE r.account_id=a.id AND COALESCE(r.is_deleted,false)=false "
                        + "AND (CAST(:of AS date) IS NULL OR r.bill_date < :of)),0) FROM accounts a WHERE a.id=:aid");
        oq.setParameter("aid", aid);
        oq.setParameter("of", dateFrom);
        opening = num(oq.getSingleResult());
        BigDecimal running = opening;
        List<Map<String, Object>> all = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            BigDecimal inAmt = num(r[7]);
            BigDecimal outAmt = num(r[8]);
            running = running.add(inAmt).subtract(outAmt);
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("billDate", norm(r[0])); m.put("billNo", norm(r[1])); m.put("checkNo", norm(r[2]));
            m.put("summary", norm(r[3])); m.put("counterpartName", norm(r[4])); m.put("source", norm(r[5]));
            m.put("settledDate", norm(r[6])); m.put("inAmount", norm(inAmt)); m.put("outAmount", norm(outAmt));
            m.put("balance", norm(running));
            all.add(m);
        }
        return paginate(cols, all, page, size);
    }

    /** X 年度对帐（GROUP BY 月，无滚动；直接分页）。 */
    @Transactional(readOnly = true)
    private ReportTableResponse executeRawGrouped(List<ReportColumn> cols, String sql, UUID pid,
                                                  LocalDate yearStart, LocalDate yearEnd, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        var dataQ = em.createNativeQuery(sql + " LIMIT :__limit OFFSET :__offset")
                .setParameter("pid", pid).setParameter("ys", yearStart).setParameter("ye", yearEnd)
                .setParameter("__limit", safeSize).setParameter("__offset", offset);
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
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
    }

    private static ReportTableResponse paginate(List<ReportColumn> cols, List<Map<String, Object>> all, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long total = all.size();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        int from = (int) Math.min((long) (safePage - 1) * safeSize, total);
        int to = (int) Math.min((long) from + safeSize, total);
        return new ReportTableResponse(cols, new ArrayList<>(all.subList(from, to)), new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
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
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
    }

    private static String normalizeDirection(String direction) {
        if (direction == null) throw new ApiException(ErrorCode.BUSINESS, "direction 必填（AR/AP）");
        String d = direction.trim().toUpperCase();
        if (!d.equals("AR") && !d.equals("AP")) throw new ApiException(ErrorCode.BUSINESS, "direction 只能是 AR 或 AP");
        return d;
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
