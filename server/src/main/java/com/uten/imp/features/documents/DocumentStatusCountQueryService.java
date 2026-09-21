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
 * <p>分桶: 通用单据 DRAFT / APPROVED / REVERSED; 采购/委外订货单另有 PENDING_FINANCE /
 * FINANCE_REJECTED(最新一条审批 case 的状态); 销售出货按六个真实阶段
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
    /** 销售出货专用: 财务已放行待出库(status 0 + finance_audit 1), 键与前端 SalesShipmentStage 逐字一致. */
    static final String FINANCE_APPROVED = "FINANCE_APPROVED";
    static final String SHIPPED = "SHIPPED";
    static final String REVERSED = "REVERSED";

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

    /** 带「财务已退回」桶的三类单据(hub 卡徽章 = 草稿 + 财务已退回). */
    static final List<String> FINANCE_REJECTED_KINDS = List.of("salesShipment", "purchaseOrder", "subcontractOrder");

    /** 仓库单据 doc_type / 出货 shipment_kind 过滤值: 只接受大写字母与下划线, 且以绑定参数下发. */
    private static final Pattern CODE = Pattern.compile("[A-Z_]{1,32}");

    record Bucket(String key, String predicate) {}

    /** 某类单据的分桶谓词(均以 o 为主表别名, 与 countSql 同一别名). */
    static List<Bucket> bucketsOf(String kind, DraftSource source) {
        String draft = "o.status = 0" + (source.extraPredicate() == null ? "" : " AND " + source.extraPredicate());
        return switch (kind) {
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
            case "purchaseOrder", "subcontractOrder" -> {
                String latest = DocumentDraftCountQueryService.latestApprovalCaseStatusSql(
                        "purchaseOrder".equals(kind) ? "PURCHASE" : "SUBCONTRACT");
                yield List.of(
                        new Bucket(DRAFT, draft),
                        new Bucket(PENDING_FINANCE, "o.status = 0 AND " + latest + " = 'PENDING'"),
                        new Bucket(FINANCE_REJECTED, "o.status = 0 AND " + latest + " = 'REJECTED'"),
                        new Bucket(APPROVED, "o.status = 1"),
                        new Bucket(REVERSED, "o.status = -1"));
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
                .append(" o WHERE o.is_deleted = false AND ").append(scopePredicate);
        if (shipmentKind) sql.append(" AND o.shipment_kind = :shipmentKind");
        if (docType) sql.append(" AND o.doc_type = :docType");
        return sql.toString();
    }

    private final EntityManager em;
    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;

    public DocumentStatusCountQueryService(EntityManager em, OwnerVisibility ownerVisibility,
                                           SecurityContextCurrentUser currentUser) {
        this.em = em;
        this.ownerVisibility = ownerVisibility;
        this.currentUser = currentUser;
    }

    /**
     * 某类单据的分桶计数. {@code shipmentKind} 只对 salesShipment 生效(客户零星发货列表传 DIRECT_CUSTOMER),
     * {@code docType} 只对 stockDocument 生效(仓库单据列表按单据类型切片); 其余类型传了即视为无效参数.
     */
    @Transactional(readOnly = true)
    public Map<String, Long> counts(String kind, String shipmentKind, String docType) {
        String kindName = kind == null ? "" : kind.trim();
        DraftSource source = KINDS.get(kindName);
        if (source == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据类型无效: " + kind);
        String kindFilter = code(shipmentKind, "salesShipment".equals(kindName), "出货类型");
        String typeFilter = code(docType, "stockDocument".equals(kindName), "仓库单据类型");
        Map<String, Long> result = new LinkedHashMap<>();
        List<Bucket> buckets = bucketsOf(kindName, source);
        buckets.forEach(bucket -> result.put(bucket.key(), 0L));
        AuthUser user = currentUser.get().orElse(null);
        if (!DocumentDraftCountQueryService.canView(user, source.viewAuthority())) return result;
        DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                source.scope(), source.viewAllAuthority(), ownerVisibility, currentUser);
        DocumentAccessPolicy.NativeReadScope scope = policy.nativeReadScope(source.ownerColumn(), "statusOwners");
        Query query = em.createNativeQuery(
                countSql(kindName, source, scope.predicate(), kindFilter != null, typeFilter != null));
        scope.bind(query);
        if (kindFilter != null) query.setParameter("shipmentKind", kindFilter);
        if (typeFilter != null) query.setParameter("docType", typeFilter);
        Object row = query.getSingleResult();
        Object[] cells = row instanceof Object[] array ? array : new Object[] {row};
        for (int i = 0; i < buckets.size() && i < cells.length; i++) {
            result.put(buckets.get(i).key(), cells[i] instanceof Number number ? number.longValue() : 0L);
        }
        return result;
    }

    /** 三类单据各自的「财务已退回」张数, 一次往返; 无权限的键固定 0. 供 hub 卡徽章与销售待办累加. */
    @Transactional(readOnly = true)
    public Map<String, Long> financeRejectedCounts() {
        AuthUser user = currentUser.get().orElse(null);
        Map<String, Long> result = new LinkedHashMap<>();
        List<String> projections = new ArrayList<>();
        List<DocumentAccessPolicy.NativeReadScope> scopes = new ArrayList<>();
        for (String kind : FINANCE_REJECTED_KINDS) {
            DraftSource source = KINDS.get(kind);
            result.put(kind, 0L);
            if (!DocumentDraftCountQueryService.canView(user, source.viewAuthority())) {
                projections.add("0");
                continue;
            }
            DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                    source.scope(), source.viewAllAuthority(), ownerVisibility, currentUser);
            DocumentAccessPolicy.NativeReadScope scope =
                    policy.nativeReadScope(source.ownerColumn(), "owners_" + kind);
            scopes.add(scope);
            String rejected = bucketsOf(kind, source).stream()
                    .filter(bucket -> FINANCE_REJECTED.equals(bucket.key()))
                    .findFirst().orElseThrow().predicate();
            projections.add("(SELECT count(*) FROM " + source.table() + " o WHERE o.is_deleted = false AND "
                    + rejected + " AND " + scope.predicate() + ")");
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
