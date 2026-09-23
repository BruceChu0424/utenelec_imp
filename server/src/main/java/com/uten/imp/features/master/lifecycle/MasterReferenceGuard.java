package com.uten.imp.features.master.lifecycle;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
import java.util.stream.Collectors;

/**
 * 主档删除前的引用检查(ADR-111)：服务端权威，一次查询给出每条记录被谁引用。
 *
 * <p>2026-09-22 事故：货品删除只做 setDeleted(true)，被有效 BOM 引用的组件被删掉后，所有
 * 用到它的成品在物料分析准备页一律报「BOM 异常」。这里把「还有谁在用它」集中成一处，查哪些表、
 * 什么状态算在用，全部登记在 {@link MasterReferenceCatalog}(真库对账测试保证每个指向主档的列
 * 都已归类)。数据库触发器(V661)只兜底旁路写入，友好原因以这里为准。
 *
 * <p>SQL 全部由目录常量拼成，唯一的绑定参数是逗号拼接的 UUID 串，经 {@code string_to_array}
 * 一次展开：批量 500 条也只有两个绑定参数、一条语句。拒绝原因里的样例标签按调用人的可见范围
 * 过滤(看不到的只计数)，不借删除报错泄露别人的单号或货品。
 */
@Component
@RequiredArgsConstructor
public class MasterReferenceGuard {

    /** 每类引用最多列出的样例条数(其余按「等共 N 处」合计)。 */
    static final int SAMPLE_LIMIT = 10;

    private final EntityManager em;
    private final MasterObjectAccess access;

    /** 一类引用：被谁引用、共几处、前几个是谁(只含调用人看得到的)。 */
    public record Blocker(RefKind kind, List<String> samples, long total) {
    }

    /**
     * 引用种类。顺序即报错文案里的先后顺序；{@code hint} 是「怎么修」的大白话。
     */
    public enum RefKind {
        BOM_PARENT("它还是以下货品的 BOM 组件", "请先在这些货品的 BOM 里移除它"),
        BOM_ROW("以下货品的 BOM 还在用它", "请先在这些货品的 BOM 里改掉它"),
        GOODS("以下货品还在用它", "请先修改这些货品"),
        CHILD_WAREHOUSE("它下面还有下级仓库", "请先删除或移走下级仓库"),
        UNIT_PROFILE("以下单位的换算基准是它", "请先修改这些单位的换算设置"),
        SALES_QUOTE("还有未审核的报价单", "请先审核或删除这些报价单"),
        SALES_ORDER("还有未结案的销售订单", "请等单据结案，或先把它从单据里去掉"),
        SHIPMENT("还有未完成的出货单", "请先处理完这些出货单"),
        SALES_OTHER_SHIPMENT("还有未审核的其它出货单", "请先处理完这些出货单"),
        SALES_RETURN("还有未审核的退货单", "请先处理完这些退货单"),
        PURCHASE_REQUEST("还有未结案的请购单", "请等单据结案，或先把它从单据里去掉"),
        PURCHASE_ORDER("还有未结案的采购订单", "请等单据结案，或先把它从单据里去掉"),
        ARRIVAL("还有没到齐的采购或委外订货", "请等货到齐，或先结案对应的订单"),
        PURCHASE_RECEIPT("还有未审核的采购收货单", "请先处理完这些收货单"),
        PURCHASE_RETURN("还有未审核的采购退货单", "请先处理完这些退货单"),
        ARRIVAL_EXCEPTION("还有没处理完的到货异常", "请先处理完这些到货异常"),
        INSPECTION("还有没检验完的货", "请先把这些货检验完"),
        IQC_REJECTION("还有没办完的来料不合格退货", "请先办完这些退货或索赔"),
        SUBCONTRACT_INQUIRY("还有未审核的委外询价单", "请先处理完这些询价单"),
        SUBCONTRACT_APPLICATION("还有未结案的委外申请", "请等单据结案，或先把它从单据里去掉"),
        SUBCONTRACT_ORDER("还有未结案的委外订单", "请等单据结案，或先把它从单据里去掉"),
        SUBCONTRACT_MATERIAL_PLAN("还有没发完料的委外订单", "请等发料完成，或先结案对应的委外订单"),
        SUBCONTRACT_MATERIAL_ISSUE("还有未审核的委外发料单", "请先处理完这些发料单"),
        SUBCONTRACT_MATERIAL_RETURN("还有未审核的委外退料单", "请先处理完这些退料单"),
        SUBCONTRACT_RECEIPT("还有未审核的委外收货单", "请先处理完这些收货单"),
        SUBCONTRACT_RETURN("还有未审核的委外退货单", "请先处理完这些退货单"),
        SUBCONTRACT_WASTE("还有未审核的委外损耗单", "请先处理完这些损耗单"),
        SUBCONTRACT_CASE("还有没处理完的委外短交或损耗", "请先处理完这些事项"),
        PRODUCTION_PLAN("还有未结案的生产计划", "请等计划结案或取消，或先把它从计划里去掉"),
        PRODUCTION_TASK("还有没完工的生产任务", "请等任务完工，或取消对应的生产计划"),
        PRODUCTION_MATERIAL("还有生产计划没领完这个料", "请等领料完成，或取消对应的生产计划"),
        DAILY_REPORT("还有未审核的生产日报", "请先处理完这些日报"),
        STOCK_DOCUMENT("还有未完成的出入库单", "请先处理完这些出入库单"),
        FINANCE_RECEIPT("还有未审核的收款单", "请先处理完这些收款单"),
        FINANCE_PAYMENT("还有未审核的付款单", "请先处理完这些付款单"),
        RECEIVABLE("还有没收完的应收款", "请先收完或核销这些应收款"),
        PAYABLE("还有没结清的应付款", "请先付清或核销这些应付款"),
        SUPPLIER_CLAIM("还有没收回的供应商索赔款", "请先收回或核销这些索赔款"),
        SUPPLIER_SETTLEMENT("还有没对完的供应商对账", "请先完成或撤销这些对账"),
        STOCK("仓库里还有库存", "请先把库存出完或盘平"),
        RESERVATION("还有没释放的库存预留", "请先释放这些预留"),
        ANALYSIS("还有进行中的物料分析", "请先完成或取消这些物料分析"),
        RD_TASK("还有进行中的研发任务", "请先完成或取消这些研发任务"),
        /** 同一批里一起删除的父件对它的 BOM 引用；父件删不成时才升级成 BOM_PARENT。 */
        BOM_INTERNAL("", "");

        private final String lead;
        private final String hint;

        RefKind(String lead, String hint) {
            this.lead = lead;
            this.hint = hint;
        }

        public String lead() { return lead; }

        public String hint() { return hint; }
    }

    /**
     * 查一批同种主档记录的引用。返回值只含「有引用」的记录；{@code excludedGoods} 是同一事务里
     * 将一起删除的货品(导入撤回：货品与它新建的颜色/单位一起撤)，它们对颜色/单位的引用不算数。
     * 货品之间的 BOM 引用见 {@link #goodsBlockers}。
     */
    public Map<UUID, List<Blocker>> blockers(
            MasterEntityKind kind, Collection<UUID> ids, Collection<UUID> excludedGoods) {
        if (ids == null || ids.isEmpty()) return Map.of();
        if (kind == MasterEntityKind.GOODS) {
            return goodsBlockers(ids);
        }
        Scan scan = run(kind, ids, excludedGoods);
        return flatten(scan.found());
    }

    /**
     * 货品删除检查。同批一起删的父件对组件的 BOM 引用先记为内部边：只有当父件因为别的原因
     * 删不成(它自己也被引用)时，它的组件才跟着删不成——否则父件留下、组件被删，正是
     * 2026-09-22 的事故形状。
     *
     * <p>不动点只在「删不成的货品集合」上迭代：集合只增不减、上限是本批条数，所以最多
     * 本批条数 + 1 轮必然停下。样例与总数在收敛之后一次拼好(外部父件的 SQL 总数 + 删不成的
     * 同批父件个数)，迭代过程中不碰截断过的样例列表。
     */
    public Map<UUID, List<Blocker>> goodsBlockers(Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) return Map.of();
        Scan scan = run(MasterEntityKind.GOODS, goodsIds, List.of());
        Map<UUID, Map<RefKind, Blocker>> found = scan.found();
        found.values().removeIf(Map::isEmpty);
        Map<UUID, Map<UUID, String>> internal = scan.internalEdges();

        Set<UUID> blocked = new HashSet<>(found.keySet());
        boolean changed = true;
        while (changed) {
            changed = false;
            for (var entry : internal.entrySet()) {
                if (blocked.contains(entry.getKey())) continue;
                if (entry.getValue().keySet().stream().anyMatch(blocked::contains)) {
                    blocked.add(entry.getKey());
                    changed = true;
                }
            }
        }

        for (var entry : internal.entrySet()) {
            List<String> blockedParents = entry.getValue().entrySet().stream()
                    .filter(parent -> blocked.contains(parent.getKey()))
                    .map(Map.Entry::getValue)
                    .sorted()
                    .toList();
            if (blockedParents.isEmpty()) continue;
            Map<RefKind, Blocker> mine = found.computeIfAbsent(
                    entry.getKey(), ignored -> new EnumMap<>(RefKind.class));
            Blocker external = mine.get(RefKind.BOM_PARENT);
            Set<String> samples = new LinkedHashSet<>(external == null ? List.of() : external.samples());
            samples.addAll(blockedParents);
            long total = (external == null ? 0 : external.total()) + blockedParents.size();
            mine.put(RefKind.BOM_PARENT, new Blocker(RefKind.BOM_PARENT,
                    samples.stream().sorted().limit(SAMPLE_LIMIT).toList(), total));
        }
        return flatten(found);
    }

    /** 拼一条给人看的拒绝原因：「XX」不能删除：1) …，…；2) …。 */
    public static String describe(MasterEntityKind kind, String label, List<Blocker> blockers) {
        StringBuilder text = new StringBuilder();
        text.append(kind.noun()).append("「").append(label == null || label.isBlank() ? "该记录" : label.strip())
                .append("」不能删除：");
        int index = 1;
        for (Blocker blocker : blockers) {
            if (index > 1) text.append("；");
            text.append(index++).append(") ").append(reason(blocker));
        }
        return text.toString();
    }

    /** 单类引用的一句话原因(批量结果逐条展示用)；看不到的样例只算进总数。 */
    public static String reason(Blocker blocker) {
        String head;
        if (blocker.samples().isEmpty()) {
            head = blocker.kind().lead() + "：共 " + blocker.total() + " 处(你没有权限查看明细，请找有权限的同事处理)";
        } else {
            long rest = blocker.total() - blocker.samples().size();
            head = blocker.kind().lead() + "：" + String.join("、", blocker.samples())
                    + (rest > 0 ? " 等共 " + blocker.total() + " 处" : "");
        }
        return head + "，" + blocker.kind().hint();
    }

    public static String reasons(List<Blocker> blockers) {
        return blockers.stream().map(MasterReferenceGuard::reason).collect(Collectors.joining("；"));
    }

    // ---- SQL 组装与执行 ------------------------------------------------------------

    /** 一次查询的结果：各记录各类引用(样例已按可见范围过滤)，以及同批父件→组件的内部边。 */
    private record Scan(Map<UUID, Map<RefKind, Blocker>> found, Map<UUID, Map<UUID, String>> internalEdges) {
    }

    /** 每种主档的整条检查语句只拼一次(目录是常量)。 */
    private static final Map<MasterEntityKind, String> SQL = new EnumMap<>(MasterEntityKind.class);

    static {
        for (MasterEntityKind kind : MasterEntityKind.values()) {
            SQL.put(kind, buildSql(kind));
        }
    }

    /** 该种主档的整条检查语句(测试用：真库上逐种执行一遍，保证目录里每段 SQL 都能跑)。 */
    static String sql(MasterEntityKind kind) {
        return SQL.get(kind);
    }

    private static String buildSql(MasterEntityKind kind) {
        List<String> branches = MasterReferenceCatalog.references(kind).stream()
                .map(MasterReferenceCatalog.Reference::sql)
                .toList();
        return """
                WITH targets(id) AS (
                    SELECT DISTINCT unnest(CAST(string_to_array(:ids, ',') AS uuid[]))
                ), excluded(id) AS (
                    SELECT DISTINCT unnest(CAST(string_to_array(:excluded, ',') AS uuid[]))
                ), hits(target, code, ref, label, owner, scope) AS (
                %s
                )
                SELECT target, code, ref, label, owner, scope, total FROM (
                    SELECT d.target, d.code, d.ref, d.label, d.owner, d.scope,
                           count(*) OVER (PARTITION BY d.target, d.code) AS total,
                           row_number() OVER (PARTITION BY d.target, d.code ORDER BY d.label, d.ref) AS rn
                    FROM (SELECT DISTINCT target, code, ref, label, owner, scope FROM hits) d
                ) ranked
                WHERE rn <= %d OR code = 'BOM_INTERNAL'
                """.formatted(String.join("\nUNION ALL\n", branches), SAMPLE_LIMIT);
    }

    private Scan run(MasterEntityKind kind, Collection<UUID> ids, Collection<UUID> excludedGoods) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(sql(kind))
                .setParameter("ids", joined(ids))
                .setParameter("excluded", joined(excludedGoods)));
        Map<String, Predicate<UUID>> readable = new HashMap<>();
        Map<UUID, Map<RefKind, List<String>>> samples = new LinkedHashMap<>();
        Map<UUID, Map<RefKind, Long>> totals = new LinkedHashMap<>();
        Map<UUID, Map<UUID, String>> internal = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID target = uuid(row[0]);
            RefKind code = RefKind.valueOf(String.valueOf(row[1]));
            String label = Objects.toString(row[3], "").strip();
            if (code == RefKind.BOM_INTERNAL) {
                // 同批父件：调用人刚刚选中并通过了写权限校验，标签无需再过滤；不截断、不计样例。
                internal.computeIfAbsent(target, ignored -> new LinkedHashMap<>())
                        .put(UUID.fromString(String.valueOf(row[2])), label);
                continue;
            }
            totals.computeIfAbsent(target, ignored -> new EnumMap<>(RefKind.class))
                    .put(code, ((Number) row[6]).longValue());
            List<String> list = samples.computeIfAbsent(target, ignored -> new EnumMap<>(RefKind.class))
                    .computeIfAbsent(code, ignored -> new ArrayList<>());
            String scope = String.valueOf(row[5]);
            UUID owner = row[4] == null ? null : uuid(row[4]);
            if (readable.computeIfAbsent(scope, access::readableLabelOwner).test(owner)) {
                list.add(label);
            }
        }
        Map<UUID, Map<RefKind, Blocker>> found = new LinkedHashMap<>();
        for (var entry : samples.entrySet()) {
            Map<RefKind, Blocker> byKind = new EnumMap<>(RefKind.class);
            for (var kindEntry : entry.getValue().entrySet()) {
                byKind.put(kindEntry.getKey(), new Blocker(kindEntry.getKey(),
                        List.copyOf(kindEntry.getValue()),
                        totals.get(entry.getKey()).get(kindEntry.getKey())));
            }
            found.put(entry.getKey(), byKind);
        }
        return new Scan(found, internal);
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID uuid ? uuid : UUID.fromString(String.valueOf(value));
    }

    private static Map<UUID, List<Blocker>> flatten(Map<UUID, Map<RefKind, Blocker>> found) {
        Map<UUID, List<Blocker>> out = new LinkedHashMap<>();
        for (var entry : found.entrySet()) {
            List<Blocker> list = entry.getValue().values().stream()
                    .filter(blocker -> blocker.kind() != RefKind.BOM_INTERNAL)
                    .sorted(Comparator.comparing(Blocker::kind))
                    .toList();
            if (!list.isEmpty()) out.put(entry.getKey(), list);
        }
        return out;
    }

    private static String joined(Collection<UUID> ids) {
        if (ids == null) return "";
        return ids.stream().filter(Objects::nonNull).map(UUID::toString).distinct()
                .collect(Collectors.joining(","));
    }
}
