package com.uten.imp.features.documents;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.documents.DocumentDraftCountQueryService.DraftSource;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 单据列表页分段计数只读查询({@code GET /api/documents/status-counts?kind=...}).
 *
 * <p>2026-09-21 用户口径: 「父分类有红色通知徽章, 子分类也要有数字」——凡 hub 单据卡挂了红徽章
 * (草稿 / 财务已退回)的列表页, 其状态分段一律带数: 草稿与财务已退回是红徽章, 其余中性括号.
 * 本服务复用 {@link DocumentDraftCountQueryService} 的单据声明(表 / 归属列 / scope / 权限),
 * 一条 SQL 用 {@code COUNT(*) FILTER} 按桶聚合, 与列表同一对象级读范围; 无该类型
 * {@code *:view} 权限时各桶固定 0 且不发 SQL.
 *
 * <p>分桶: 通用单据 DRAFT / APPROVED / REVERSED; 销售报价(ADR-134)另有 PENDING_FINANCE(待财务核价) /
 * FINANCE_REJECTED(财务退回); 采购/委外订货单另有 PENDING_FINANCE /
 * FINANCE_REJECTED(最新一条审批 case 的状态); 委外订货另有 EXECUTING(已审且未结案),
 * 保留 APPROVED 的已审总数; 销售出货按六个真实阶段
 * (DRAFT / PENDING_FINANCE / FINANCE_REJECTED / FINANCE_APPROVED=财务已放行待出库 / SHIPPED / REVERSED,
 * 逐条与 SalesShipmentService.addStagePredicates 一致). DRAFT 桶就是草稿计数的口径
 * (同一 extraPredicate), 保证列表「草稿」段与 hub 卡草稿徽章同数.
 */
@Service
public class DocumentStatusCountQueryService {

    static final String DRAFT = "DRAFT";
    static final String PENDING_FINANCE = "PENDING_FINANCE";
    static final String FINANCE_REJECTED = "FINANCE_REJECTED";
    static final String APPROVED = "APPROVED";
    /** 委外订货执行中: 财务已通过且链路未结案, 不含已结案的 APPROVED 记录。 */
    static final String EXECUTING = "EXECUTING";
    /** 销售出货专用: 财务已放行待出库(status 0 + finance_audit 1), 键与前端 SalesShipmentStage 逐字一致. */
    static final String FINANCE_APPROVED = "FINANCE_APPROVED";
    static final String SHIPPED = "SHIPPED";
    static final String REVERSED = "REVERSED";
    static final String PENDING_GL_CONFIRMATION = "PENDING_GL_CONFIRMATION";

    /** 前端 DraftDocKind.name → 单据声明(顺序无关, 键必须与前端枚举名逐字一致). */
    static final Map<String, DraftSource> KINDS = Map.ofEntries(
            Map.entry("salesOrder", DocumentDraftCountQueryService.SALES_ORDER),
            Map.entry("salesShipment", DocumentDraftCountQueryService.SALES_SHIPMENT),
            Map.entry("salesReturn", DocumentDraftCountQueryService.SALES_RETURN),
            Map.entry("salesQuote", DocumentDraftCountQueryService.SALES_QUOTE),
            Map.entry("purchaseOrder", DocumentDraftCountQueryService.PURCHASE_ORDER),
            Map.entry("subcontractOrder", DocumentDraftCountQueryService.SUBCONTRACT_ORDER),
            Map.entry("stockDocument", DocumentDraftCountQueryService.STOCK_DOCUMENT),
            Map.entry("productionPlan", DocumentDraftCountQueryService.PRODUCTION_PLAN),
            Map.entry("productionDailyReport", DocumentDraftCountQueryService.PRODUCTION_DAILY_REPORT),
            Map.entry("financeReceipt", DocumentDraftCountQueryService.FINANCE_RECEIPT),
            Map.entry("financePayment", DocumentDraftCountQueryService.FINANCE_PAYMENT),
            Map.entry("financeExpense", DocumentDraftCountQueryService.FINANCE_EXPENSE),
            Map.entry("financeOtherIncome", DocumentDraftCountQueryService.FINANCE_OTHER_INCOME),
            Map.entry("financeBankTransfer", DocumentDraftCountQueryService.FINANCE_BANK_TRANSFER),
            Map.entry("purchaseReceipt", DocumentDraftCountQueryService.PURCHASE_RECEIPT),
            Map.entry("purchaseReturn", DocumentDraftCountQueryService.PURCHASE_RETURN),
            Map.entry("subcontractReturn", DocumentDraftCountQueryService.SUBCONTRACT_RETURN),
            Map.entry("subcontractMaterialReturn", DocumentDraftCountQueryService.SUBCONTRACT_MATERIAL_RETURN),
            Map.entry("subcontractWaste", DocumentDraftCountQueryService.SUBCONTRACT_WASTE),
            Map.entry("stockTransfer", DocumentDraftCountQueryService.STOCK_TRANSFER),
            Map.entry("stockCheck", DocumentDraftCountQueryService.STOCK_CHECK));

    /** 带「财务已退回」桶的四类单据(hub 卡徽章 = 草稿 + 财务已退回; 报价 ADR-134 起由财务核价). */
    static final List<String> FINANCE_REJECTED_KINDS =
            List.of("salesShipment", "salesQuote", "purchaseOrder", "subcontractOrder");

    /** 仓库单据 doc_type / 出货 shipment_kind 过滤值: 只接受大写字母与下划线, 且以绑定参数下发. */
    private static final Pattern CODE = Pattern.compile("[A-Z_]{1,32}");

    record Bucket(String key, String predicate) {}

    /** 某类单据的分桶谓词(均以 o 为主表别名, 与 countSql 同一别名). */
    static List<Bucket> bucketsOf(String kind, DraftSource source) {
        String draft = "o.status = 0" + (source.extraPredicate() == null ? "" : " AND " + source.extraPredicate());
        return switch (kind) {
            case "financeExpense" -> List.of(
                    new Bucket(DRAFT, draft),
                    new Bucket(PENDING_GL_CONFIRMATION,
                            "o.legacy_id IS NULL AND o.status = 1 AND o.gl_status = 1"),
                    new Bucket(APPROVED, "o.status = 1"),
                    new Bucket(REVERSED, "o.status = -1"));
            case "salesShipment" -> List.of(
                    new Bucket(DRAFT, draft),
                    new Bucket(PENDING_FINANCE, "o.status = 0 AND o.shipment_kind <> 'LEGACY' AND o.rejected = false"
                            + " AND o.finance_rejected = false AND o.finance_audit = 0"
                            + " AND (o.finance_gate_version < 2 OR (o.sales_confirmed_at IS NOT NULL"
                            + " AND o.sales_confirmed_revision = o.review_revision))"),
                    new Bucket(FINANCE_REJECTED, "o.status = 0 AND o.shipment_kind <> 'LEGACY' AND o.finance_rejected = true"),
                    new Bucket(FINANCE_APPROVED, "o.status = 0 AND o.shipment_kind <> 'LEGACY' AND o.rejected = false AND o.finance_audit = 1"),
                    new Bucket(SHIPPED, "o.status = 1"),
                    new Bucket(REVERSED, "o.status = -1"));
            // ADR-134 报价核价: 0 草稿(退回原因空) / 0 + 退回原因 = 财务已退回 / 2 待财务核价 / 1 已核价 / -1 作废.
            case "salesQuote" -> List.of(
                    new Bucket(DRAFT, draft),
                    new Bucket(PENDING_FINANCE, "o.status = 2"),
                    new Bucket(FINANCE_REJECTED, "o.status = 0 AND o.finance_return_reason IS NOT NULL"),
                    new Bucket(APPROVED, "o.status = 1"),
                    new Bucket(REVERSED, "o.status = -1"));
            case "purchaseOrder", "subcontractOrder" -> {
                String latest = DocumentDraftCountQueryService.latestApprovalCaseStatusSql(
                        "purchaseOrder".equals(kind) ? "PURCHASE" : "SUBCONTRACT");
                List<Bucket> buckets = new ArrayList<>(List.of(
                        new Bucket(DRAFT, draft),
                        new Bucket(PENDING_FINANCE, "o.status IN (0, 1) AND " + latest + " = 'PENDING'"),
                        new Bucket(FINANCE_REJECTED, "o.status IN (0, 1) AND " + latest + " = 'REJECTED'"),
                        new Bucket(APPROVED, "o.status = 1"),
                        new Bucket(REVERSED, "o.status = -1")));
                if ("subcontractOrder".equals(kind)) {
                    buckets.add(new Bucket(EXECUTING, "o.status = 1 AND o.is_closed = false AND "
                            + latest + " NOT IN ('PENDING', 'REJECTED')"));
                }
                yield List.copyOf(buckets);
            }
            default -> List.of(
                    new Bucket(DRAFT, draft),
                    new Bucket(APPROVED, "o.status = 1"),
                    new Bucket(REVERSED, "o.status = -1"));
        };
    }

    /** 组装一条分桶 SQL(不含绑定); 表名 / 谓词全为编译期常量, 归属谓词只含具名参数. */
    static String countSql(String kind, DraftSource source, String scopePredicate,
                           boolean shipmentKind, boolean docType) {
        List<String> projections = new ArrayList<>();
        for (Bucket bucket : bucketsOf(kind, source)) {
            projections.add("COUNT(*) FILTER (WHERE " + bucket.predicate() + ")");
        }
        StringBuilder sql = new StringBuilder("SELECT ").append(String.join(", ", projections))
                .append(" FROM ").append(source.table())
                .append(" o WHERE o.is_deleted = false AND ")
                .append(DocumentDraftCountQueryService.currentSourcePredicate(source))
                .append(" AND ").append(scopePredicate);
        if (shipmentKind) sql.append(" AND o.shipment_kind = :shipmentKind");
        if (docType) sql.append(" AND o.doc_type = :docType");
        return sql.toString();
    }

    private final EntityManager em;
    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.TaskAudiencePort taskAudience;
    /** ADR-149 仓库数据范围; 未注入(直接 new 的单测)时不按仓库裁剪。 */
    private com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes;

    public DocumentStatusCountQueryService(EntityManager em, OwnerVisibility ownerVisibility,
                                           SecurityContextCurrentUser currentUser) {
        this.em = em;
        this.ownerVisibility = ownerVisibility;
        this.currentUser = currentUser;
    }

    @org.springframework.beans.factory.annotation.Autowired(required = false)
    void setWarehouseScopes(com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes) {
        this.warehouseScopes = warehouseScopes;
    }

    /** 兼容调用: 本人默认仓库数据范围。 */
    @Transactional(readOnly = true)
    public Map<String, Long> counts(String kind, String shipmentKind, String docType) {
        return counts(kind, shipmentKind, docType, null);
    }

    /**
     * 某类单据的分桶计数. {@code shipmentKind} 只对 salesShipment 生效(客户零星发货列表传 DIRECT_CUSTOMER),
     * {@code docType} 只对 stockDocument 生效(仓库单据列表按单据类型切片); 其余类型传了即视为无效参数.
     */
    @Transactional(readOnly = true)
    public Map<String, Long> counts(String kind, String shipmentKind, String docType, java.util.UUID scopeWarehouseId) {
        String kindName = kind == null ? "" : kind.trim();
        DraftSource source = KINDS.get(kindName);
        if (source == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据类型无效: " + kind);
        boolean warehouseScoped = DocumentDraftCountQueryService.WAREHOUSE_SCOPED.contains(source);
        if (!warehouseScoped && scopeWarehouseId != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "这类单据不按仓库范围计数");
        }
        String kindFilter = code(shipmentKind, "salesShipment".equals(kindName), "出货类型");
        String typeFilter = code(docType, "stockDocument".equals(kindName), "仓库单据类型");
        Map<String, Long> result = new LinkedHashMap<>();
        List<Bucket> buckets = bucketsOf(kindName, source);
        buckets.forEach(bucket -> result.put(bucket.key(), 0L));
        AuthUser user = currentUser.get().orElse(null);
        String viewAuthority = source == DocumentDraftCountQueryService.SALES_SHIPMENT
                && "DIRECT_CUSTOMER".equals(kindFilter) ? "sales_other_shipment:view" : source.viewAuthority();
        if (!DocumentDraftCountQueryService.canView(user, viewAuthority)) return result;
        DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                source.scope(), source.viewAllAuthority(), ownerVisibility, currentUser);
        DocumentAccessPolicy.NativeReadScope scope = policy.nativeReadScope(source.ownerColumn(), "statusOwners");
        // ADR-149: 仓库单据的分段数与库存单据列表同一仓库数据范围(发出仓或调入仓)。
        var warehouseScope = warehouseScoped && warehouseScopes != null
                ? warehouseScopes.current(scopeWarehouseId)
                : com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.ALL;
        String predicate = scope.predicate() + (warehouseScope.active()
                ? " AND " + DocumentDraftCountQueryService.WAREHOUSE_SCOPE_PREDICATE : "");
        Query query = em.createNativeQuery(
                countSql(kindName, source, predicate, kindFilter != null, typeFilter != null));
        scope.bind(query);
        if (warehouseScope.active()) {
            // 本人默认范围(没挑仓)时自己的草稿不论仓都算, 与库存单据列表同一判定; 挑了仓只看那个仓。
            AuthUser me = currentUser.get().orElse(null);
            DocumentDraftCountQueryService.bindWarehouseScope(query, warehouseScope,
                    scopeWarehouseId == null && me != null && me.getEmployeeId() != null
                            ? me.getEmployeeId().toString() : "");
        }
        if (kindFilter != null) query.setParameter("shipmentKind", kindFilter);
        if (typeFilter != null) query.setParameter("docType", typeFilter);
        Object row = query.getSingleResult();
        Object[] cells = row instanceof Object[] array ? array : new Object[] {row};
        for (int i = 0; i < buckets.size() && i < cells.length; i++) {
            result.put(buckets.get(i).key(), cells[i] instanceof Number number ? number.longValue() : 0L);
        }
        // ACTIONABLE_*/RESPONSIBLE_* 桶按会话主体直通（browsingRead）算：本端点直连
        // 各单据列表/任务中心的分段徽章，须与列表本身、工作台徽章汇总同一可见口径；
        // read() 会剥掉超管镜像权限，把页面上的草稿/退回/待审分段徽章全算成 0
        //（2026-10-19 与 WorkbenchBadgeService 同修）。
        result.putAll(taskAudience.browsingRead(() -> actionableCounts(
                kindName, source, kindFilter, typeFilter, scopeWarehouseId)));
        return result;
    }

    private Map<String, Long> actionableCounts(String kind, DraftSource source,
            String shipmentKind, String docType, java.util.UUID requestedWarehouse) {
        Map<String, Long> result = new LinkedHashMap<>();
        var taskBuckets = bucketsOf(kind, source).stream().filter(bucket ->
                List.of(DRAFT, FINANCE_REJECTED, PENDING_GL_CONFIRMATION,
                        PENDING_FINANCE, FINANCE_APPROVED, EXECUTING).contains(bucket.key())).toList();
        taskBuckets.forEach(bucket -> result.put(taskBucketKey(bucket.key()), 0L));
        AuthUser user = currentUser.get().orElse(null);
        boolean resume = DocumentDraftCountQueryService.canResume(user, source);
        boolean rejected = canCorrectRejected(user, source);
        boolean gl = "financeExpense".equals(kind)
                && DocumentDraftCountQueryService.canView(user, "finance_expense:view")
                && DocumentDraftCountQueryService.canView(user, "finance_expense:gl_confirm");
        if (!resume && !rejected && !gl) return result;
        DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                source.scope(), source.viewAllAuthority(), ownerVisibility, currentUser);
        var writeScope = policy.nativeReadScope(source.ownerColumn(), "taskStatusOwners",
                DocumentDraftCountQueryService.writableScope(policy));
        var readScope = policy.nativeReadScope(source.ownerColumn(), "taskStatusReadOwners");
        List<String> projections = new ArrayList<>();
        for (Bucket bucket : taskBuckets) {
            boolean allowed = FINANCE_REJECTED.equals(bucket.key()) ? rejected
                    : PENDING_GL_CONFIRMATION.equals(bucket.key()) ? gl : resume;
            String owner = PENDING_GL_CONFIRMATION.equals(bucket.key()) ? readScope.predicate() : writeScope.predicate();
            String actions = FINANCE_REJECTED.equals(bucket.key())
                    ? correctionPredicate(user, source) : DocumentDraftCountQueryService.actionPredicate(user, source);
            if (PENDING_GL_CONFIRMATION.equals(bucket.key())) actions = "1=1";
            projections.add(allowed ? "COUNT(*) FILTER (WHERE " + bucket.predicate() + " AND " + owner
                    + " AND " + source.ownerColumn() + " IS NOT NULL AND " + actions + ")" : "0");
        }
        var warehouse = DocumentDraftCountQueryService.WAREHOUSE_SCOPED.contains(source) && warehouseScopes != null
                ? warehouseScopes.current(requestedWarehouse)
                : com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.ALL;
        String sql = "SELECT " + String.join(", ", projections) + " FROM " + source.table()
                + " o WHERE o.is_deleted = false AND " + DocumentDraftCountQueryService.currentSourcePredicate(source)
                + (shipmentKind == null ? "" : " AND o.shipment_kind=:shipmentKind")
                + (docType == null ? "" : " AND o.doc_type=:docType")
                + (warehouse.active() ? " AND " + DocumentDraftCountQueryService.WAREHOUSE_SCOPE_PREDICATE : "");
        Query query = em.createNativeQuery(sql);
        if (sql.contains(":taskStatusOwners")) writeScope.bind(query);
        if (sql.contains(":taskStatusReadOwners")) readScope.bind(query);
        if (shipmentKind != null) query.setParameter("shipmentKind", shipmentKind);
        if (docType != null) query.setParameter("docType", docType);
        if (warehouse.active()) DocumentDraftCountQueryService.bindWarehouseScope(query, warehouse,
                requestedWarehouse == null && user != null && user.getEmployeeId() != null
                        ? user.getEmployeeId().toString() : "");
        Object raw = query.getSingleResult();
        Object[] row = raw instanceof Object[] values ? values : new Object[] {raw};
        int index = 0;
        for (String key : result.keySet()) {
            result.put(key, index < row.length && row[index] instanceof Number n ? n.longValue() : 0L);
            index++;
        }
        return result;
    }

    private static String taskBucketKey(String bucket) {
        return (List.of(PENDING_FINANCE, FINANCE_APPROVED, EXECUTING).contains(bucket)
                ? "RESPONSIBLE_" : "ACTIONABLE_") + bucket;
    }

    static boolean canCorrectRejected(AuthUser user, DraftSource source) {
        return !"1=0".equals(correctionPredicate(user, source));
    }

    static String correctionPredicate(AuthUser user, DraftSource source) {
        if (source == DocumentDraftCountQueryService.SALES_SHIPMENT) {
            boolean order = canEdit(user, "sales_shipment");
            boolean direct = canEdit(user, "sales_other_shipment");
            if (order && direct) return "1=1";
            if (order) return "o.shipment_kind <> 'DIRECT_CUSTOMER'";
            if (direct) return "o.shipment_kind = 'DIRECT_CUSTOMER'";
            return "1=0";
        }
        String family = source.viewAuthority().substring(0, source.viewAuthority().lastIndexOf(':'));
        return canEdit(user, family) ? "1=1" : "1=0";
    }

    private static boolean canEdit(AuthUser user, String family) {
        return DocumentDraftCountQueryService.canView(user, family + ":view")
                && DocumentDraftCountQueryService.canView(user, family + ":edit");
    }

    /** 各类单据的「财务已退回」张数, 一次往返; 无权限的键固定 0. 供 hub 卡徽章与销售待办累加. */
    @Transactional(readOnly = true)
    @com.uten.imp.security.BusinessTaskRead
    public Map<String, Long> financeRejectedCounts() {
        AuthUser user = currentUser.get().orElse(null);
        Map<String, Long> result = new LinkedHashMap<>();
        List<String> projections = new ArrayList<>();
        List<DocumentAccessPolicy.NativeReadScope> scopes = new ArrayList<>();
        for (String kind : FINANCE_REJECTED_KINDS) {
            DraftSource source = KINDS.get(kind);
            result.put(kind, 0L);
            if (!canCorrectRejected(user, source)) {
                projections.add("0");
                continue;
            }
            DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                    source.scope(), source.viewAllAuthority(), ownerVisibility, currentUser);
            DocumentAccessPolicy.NativeReadScope scope =
                    policy.nativeReadScope(source.ownerColumn(), "owners_" + kind,
                            DocumentDraftCountQueryService.writableScope(policy));
            scopes.add(scope);
            String rejected = bucketsOf(kind, source).stream()
                    .filter(bucket -> FINANCE_REJECTED.equals(bucket.key()))
                    .findFirst().orElseThrow().predicate();
            projections.add("(SELECT count(*) FROM " + source.table() + " o WHERE o.is_deleted = false AND "
                    + DocumentDraftCountQueryService.currentSourcePredicate(source) + " AND "
                    + rejected + " AND " + source.ownerColumn() + " IS NOT NULL AND " + scope.predicate()
                    + " AND " + correctionPredicate(user, source) + ")");
        }
        if (scopes.isEmpty()) return result;
        Query query = em.createNativeQuery("SELECT " + String.join(", ", projections));
        scopes.forEach(scope -> scope.bind(query));
        Object row = query.getSingleResult();
        Object[] cells = row instanceof Object[] array ? array : new Object[] {row};
        int i = 0;
        for (String kind : FINANCE_REJECTED_KINDS) {
            result.put(kind, i < cells.length && cells[i] instanceof Number number ? number.longValue() : 0L);
            i++;
        }
        return result;
    }

    private static String code(String raw, boolean allowed, String label) {
        if (raw == null || raw.isBlank()) return null;
        String value = raw.trim().toUpperCase(java.util.Locale.ROOT);
        if (!allowed || !CODE.matcher(value).matches()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "筛选无效: " + raw);
        }
        return value;
    }
}
