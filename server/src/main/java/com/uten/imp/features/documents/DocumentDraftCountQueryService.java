package com.uten.imp.features.documents;

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

/**
 * 全模块草稿计数只读查询（{@code GET /api/documents/drafts/count} 的数据源）。
 *
 * <p>口径（每个单据类型一条等价 SQL）：
 * <pre>
 *   SELECT count(*) FROM &lt;表&gt; o
 *    WHERE o.is_deleted = false AND o.status = 0 AND &lt;对象级归属谓词&gt;
 * </pre>
 * 其中「对象级归属谓词」直接复用各模块 {@link DocumentAccessPolicy#nativeReadScope} 的产物
 * （超管 / {@code *:view:all} → {@code 1=1}；否则 {@code 归属列 IS NULL OR 归属列 IN (:owners)}），
 * 因此 hub 徽章与对应列表页「草稿」段永远同口径。
 *
 * <p>两条额外规则：
 * <ul>
 *   <li><b>权限自卫</b>：没有该类型 {@code *:view} 权限（且非超管）时直接返回 0，不发 SQL。</li>
 *   <li><b>销售订货单去重</b>：额外要求 {@code finance_rejected = false}。财务驳回单同样是
 *       {@code status = 0}，但已计入销售关注徽章的 REJECTED 桶，若此处再数一次就会双计。
 *       故草稿计数的语义是「待自审的新建/修订草稿」，驳回件继续走驳回徽章。</li>
 *   <li><b>仓库单据切片</b>：{@code stock_documents} 一张表装 8 种单据，除整表合计
 *       （{@code stockDocument}）外再按 {@code doc_type} 切出调拨 / 盘点两类，
 *       供仓库 hub 的两张卡各显各的数——前端择一展示，不得同时用合计与切片（会双计）。</li>
 * </ul>
 *
 * <p>21 条 count 都是走 {@code (status, is_deleted, 归属列)} 索引的廉价聚合，放在同一个只读
 * 事务里一次往返返回，不做 N+1 的行级展开。
 *
 * <p><b>呈现约束</b>：本服务产出的全部数字都是「浏览型计数」（我还有多少张没提交），
 * 前端渲染成中性括号数字且不进上层待办累加；真正的「需要我处理」待办走各模块自己的
 * 待办计数端点。见 {@code docs/00-项目准则/14-徽章与计数口径.md}。
 */
@Service
public class DocumentDraftCountQueryService {

    /** 归属范围参数名；每条 count 各自独立编译，可安全复用同一个名字。 */
    private static final String OWNER_PARAM = "draftOwners";

    /**
     * 一种草稿单据的声明。
     *
     * @param table            主表名（编译期常量，从不来自入参）
     * @param ownerColumn      归属列（带 {@code o.} 前缀）
     * @param scope            {@code user_data_scopes.scope} 归属范围名
     * @param viewAllAuthority 旁路归属限制的 {@code *:view:all} 权限码
     * @param viewAuthority    读取该类型所需的 {@code *:view} 权限码
     * @param extraPredicate   附加谓词（可为 null）
     */
    record DraftSource(
            String table,
            String ownerColumn,
            String scope,
            String viewAllAuthority,
            String viewAuthority,
            String extraPredicate) {
    }

    // —— 销售：订货/出货/退货的归属列是 owner_employee_id，报价沿用 maker_id（与 SalesQuoteService 一致）——
    static final DraftSource SALES_ORDER = new DraftSource(
            "sales_orders", "o.owner_employee_id", "sales", "sales:view:all",
            "sales_order:view", "o.finance_rejected = false");
    static final DraftSource SALES_SHIPMENT = new DraftSource(
            "sales_shipments", "o.owner_employee_id", "sales", "sales:view:all",
            "sales_shipment:view", null);
    static final DraftSource SALES_RETURN = new DraftSource(
            "sales_returns", "o.owner_employee_id", "sales", "sales:view:all",
            "sales_return:view", null);
    static final DraftSource SALES_QUOTE = new DraftSource(
            "sales_quotes", "o.maker_id", "sales", "sales:view:all",
            "sales_quote:view", null);

    static final DraftSource PURCHASE_ORDER = new DraftSource(
            "purchase_orders", "o.maker_id", "purchase", "purchase:view:all",
            "purchase_order:view", null);
    static final DraftSource SUBCONTRACT_ORDER = new DraftSource(
            "subcontract_orders", "o.maker_id", "subcontract", "subcontract:view:all",
            "subcontract_order:view", null);
    static final DraftSource STOCK_DOCUMENT = new DraftSource(
            "stock_documents", "o.maker_id", "stock_doc", "stock_doc:view:all",
            "stock_doc:view", null);

    // 生产计划与生产日报共用 production_plan 归属范围（见 ProductionDocumentAccessPolicy），
    // 但各自有独立的 :view 权限码。
    static final DraftSource PRODUCTION_PLAN = new DraftSource(
            "production_plans", "o.maker_id", "production_plan", "production_plan:view:all",
            "production_plan:view", null);
    static final DraftSource PRODUCTION_DAILY_REPORT = new DraftSource(
            "production_daily_reports", "o.maker_id", "production_plan", "production_plan:view:all",
            "production_daily_report:view", null);

    static final DraftSource FINANCE_RECEIPT = new DraftSource(
            "finance_receipts", "o.maker_id", "finance", "finance:view:all",
            "finance_receipt:view", null);
    static final DraftSource FINANCE_PAYMENT = new DraftSource(
            "finance_payments", "o.maker_id", "finance", "finance:view:all",
            "finance_payment:view", null);
    static final DraftSource FINANCE_EXPENSE = new DraftSource(
            "finance_expenses", "o.maker_id", "finance", "finance:view:all",
            "finance_expense:view", null);
    static final DraftSource FINANCE_OTHER_INCOME = new DraftSource(
            "finance_other_incomes", "o.maker_id", "finance", "finance:view:all",
            "finance_other_income:view", null);
    static final DraftSource FINANCE_BANK_TRANSFER = new DraftSource(
            "finance_bank_transfers", "o.maker_id", "finance", "finance:view:all",
            "finance_bank_transfer:view", null);

    // —— 2026-09-11 补齐：采购收货/退货、委外三类退回与损耗、仓库调拨/盘点 ——
    // 这 7 张 hub 卡此前一个数字都没有，用户进去才知道自己还有没提交的单。
    // 归属列/scope/viewAll 与各模块既有 DocumentAccessPolicy 薄壳完全一致
    //（PurchaseDocumentAccessPolicy / SubcontractDocumentAccessPolicy / StockDocAccessPolicy）。
    static final DraftSource PURCHASE_RECEIPT = new DraftSource(
            "purchase_receipts", "o.maker_id", "purchase", "purchase:view:all",
            "purchase_receipt:view", null);
    static final DraftSource PURCHASE_RETURN = new DraftSource(
            "purchase_returns", "o.maker_id", "purchase", "purchase:view:all",
            "purchase_return:view", null);
    static final DraftSource SUBCONTRACT_RETURN = new DraftSource(
            "subcontract_returns", "o.maker_id", "subcontract", "subcontract:view:all",
            "subcontract_return:view", null);
    static final DraftSource SUBCONTRACT_MATERIAL_RETURN = new DraftSource(
            "subcontract_material_returns", "o.maker_id", "subcontract", "subcontract:view:all",
            "subcontract_material_return:view", null);
    static final DraftSource SUBCONTRACT_WASTE = new DraftSource(
            "subcontract_wastes", "o.maker_id", "subcontract", "subcontract:view:all",
            "subcontract_waste:view", null);
    // 仓库调拨 / 盘点：与 STOCK_DOCUMENT 同表同权限，只多一个 doc_type 切片谓词
    //（编译期常量，走 idx_sd_type_date 的 doc_type 前缀）。
    static final DraftSource STOCK_TRANSFER = new DraftSource(
            "stock_documents", "o.maker_id", "stock_doc", "stock_doc:view:all",
            "stock_doc:view", "o.doc_type = 'TRANSFER'");
    static final DraftSource STOCK_CHECK = new DraftSource(
            "stock_documents", "o.maker_id", "stock_doc", "stock_doc:view:all",
            "stock_doc:view", "o.doc_type = 'CHECK'");

    /** 响应字段顺序（与 {@link DraftCountsResponse} 的构造参数顺序一一对应）。 */
    static final List<DraftSource> SOURCES = List.of(
            SALES_ORDER, SALES_SHIPMENT, SALES_RETURN, SALES_QUOTE,
            PURCHASE_ORDER, SUBCONTRACT_ORDER, STOCK_DOCUMENT,
            PRODUCTION_PLAN, PRODUCTION_DAILY_REPORT,
            FINANCE_RECEIPT, FINANCE_PAYMENT, FINANCE_EXPENSE,
            FINANCE_OTHER_INCOME, FINANCE_BANK_TRANSFER,
            PURCHASE_RECEIPT, PURCHASE_RETURN,
            SUBCONTRACT_RETURN, SUBCONTRACT_MATERIAL_RETURN, SUBCONTRACT_WASTE,
            STOCK_TRANSFER, STOCK_CHECK);

    private final EntityManager em;
    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;

    public DocumentDraftCountQueryService(EntityManager em,
                                          OwnerVisibility ownerVisibility,
                                          SecurityContextCurrentUser currentUser) {
        this.em = em;
        this.ownerVisibility = ownerVisibility;
        this.currentUser = currentUser;
    }

    /**
     * 组装单条 count SQL。表名/列名/附加谓词全是编译期常量，归属范围谓词由
     * {@link DocumentAccessPolicy.NativeReadScope} 生成且只含具名参数——无拼接注入面。
     */
    static String countSql(DraftSource source, String scopePredicate) {
        StringBuilder sql = new StringBuilder("SELECT count(*) FROM ")
                .append(source.table())
                .append(" o WHERE o.is_deleted = false AND o.status = 0");
        if (source.extraPredicate() != null) {
            sql.append(" AND ").append(source.extraPredicate());
        }
        return sql.append(" AND ").append(scopePredicate).toString();
    }

    /**
     * 全部 21 类草稿计数；未登录或全无权限时各项为 0。
     *
     * <p><b>一次往返</b>（2026-09-11 修）：此前是每个类型各发一条 count，而且每条都
     * 重新算一遍归属范围——{@code OwnerVisibility.evaluate} 对非超管要查「交接继承」
     * 和「授权归属人」两条 SQL。21 个类型 × 3 条 ≈ 63 次数据库往返，现场表现为
     * 新建页的「草稿」徽章要等十几秒才出现。
     *
     * <p>现在：
     * <ul>
     *   <li>归属范围<b>按 scope 串去重</b>只算一次（21 个类型只有 6 个不同 scope），
     *       同一 scope 共用一个绑定参数；</li>
     *   <li>21 条 count 合并成<b>一条</b> {@code SELECT (子查询), (子查询), ...}；
     *       每个子查询仍是走 {@code (status, is_deleted, 归属列)} 索引的廉价聚合。</li>
     * </ul>
     * 权限自卫不变：没有该类型 {@code *:view} 的，位置上直接写字面量 0，不进 SQL。
     */
    @Transactional(readOnly = true)
    public DraftCountsResponse counts() {
        AuthUser user = currentUser.get().orElse(null);
        long[] values = new long[SOURCES.size()];
        // scope 串 → 该 scope 的归属范围（含绑定参数名）。同一个 scope 只算一次。
        Map<String, ScopeBinding> byScope = new LinkedHashMap<>();
        List<String> projections = new ArrayList<>(SOURCES.size());
        boolean anyQueryable = false;

        for (DraftSource source : SOURCES) {
            if (!canView(user, source.viewAuthority())) {
                projections.add("0");
                continue;
            }
            ScopeBinding binding = byScope.computeIfAbsent(source.scope(), scopeName -> {
                DocumentAccessPolicy policy = new DraftScopeAccessPolicy(
                        scopeName, source.viewAllAuthority(), ownerVisibility, currentUser);
                return new ScopeBinding(
                        policy, OWNER_PARAM + "_" + byScope.size(), policy.scope());
            });
            DocumentAccessPolicy.NativeReadScope readScope = binding.policy()
                    .nativeReadScope(
                            source.ownerColumn(), binding.parameterName(), binding.ownerScope());
            projections.add("(" + countSql(source, readScope.predicate()) + ")");
            anyQueryable = true;
        }

        if (anyQueryable) {
            Query query = em.createNativeQuery("SELECT " + String.join(", ", projections));
            // 每个 scope 的归属集合只绑一次，且只在非空时绑（seeAll / 空集分支的
            // 谓词里没有具名参数，绑 null 会让 Hibernate 推断不出类型）。
            for (ScopeBinding binding : byScope.values()) {
                if (!binding.ownerScope().seeAll()
                        && !binding.ownerScope().visibleOwners().isEmpty()) {
                    query.setParameter(binding.parameterName(), binding.ownerScope().visibleOwners());
                }
            }
            Object row = query.getSingleResult();
            Object[] cells = row instanceof Object[] array ? array : new Object[] {row};
            for (int i = 0; i < values.length && i < cells.length; i++) {
                values[i] = cells[i] instanceof Number number ? number.longValue() : 0L;
            }
        }

        // 顺序由 SOURCES 决定；DocumentDraftCountSqlContractTest 逐字段比对
        // SOURCES ↔ DraftCountsResponse 的记录组件，错位会在测试里直接炸。
        return new DraftCountsResponse(
                values[0], values[1], values[2], values[3], values[4],
                values[5], values[6], values[7], values[8], values[9],
                values[10], values[11], values[12], values[13], values[14],
                values[15], values[16], values[17], values[18], values[19],
                values[20]);
    }

    /** 一个 scope 串对应的归属范围：策略、绑定参数名、已算好的范围（只算一次）。 */
    private record ScopeBinding(
            DocumentAccessPolicy policy,
            String parameterName,
            OwnerVisibility.OwnerScope ownerScope) {}

    private static boolean canView(AuthUser user, String authority) {
        if (user == null) {
            return false;
        }
        return user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority()));
    }
}
