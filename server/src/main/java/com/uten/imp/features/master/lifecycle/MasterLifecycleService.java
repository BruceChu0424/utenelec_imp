package com.uten.imp.features.master.lifecycle;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchResult;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
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
 * 主档的删除 / 批量启停 / 批量删除(ADR-111)。所有主档共用这一条写路径：
 *
 * <ol>
 *   <li>一条 {@code SELECT … FOR UPDATE} 按 id 顺序锁住本批记录(防死锁、读到当前版本)；</li>
 *   <li>逐条做对象级授权与乐观锁版本比对，删除再加一次引用检查({@link MasterReferenceGuard})；</li>
 *   <li>一条 {@code UPDATE} 写入全部放行的记录；货品删除先在同一事务里软删它自己的 BOM 行。</li>
 * </ol>
 *
 * <p>批量命令逐条返回结果(部分成功照常提交)，单条删除失败直接抛出中文原因。表名来自
 * {@link MasterEntityKind} 白名单；id 以一个逗号串参数绑定，批量 500 条也不展开成 500 个参数。
 */
@Service
@RequiredArgsConstructor
public class MasterLifecycleService {

    static final Set<String> STATUSES = Set.of("使用", "禁用");

    private static final String ID_ARRAY = "CAST(string_to_array(:ids, ',') AS uuid[])";
    private static final String ACTOR =
            "COALESCE(CAST(NULLIF(current_setting('app.actor_id', true), '') AS uuid), updated_by)";
    /** 分类级联删除失败时最多列出的货品/模具条数。 */
    private static final int CASCADE_SAMPLE_LIMIT = 5;

    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterReferenceGuard guard;
    private final MasterObjectAccess access;

    /** 锁定行快照。 */
    private record Row(UUID id, long version, UUID owner, String status, String label) {
    }

    // ---- 单条删除 -----------------------------------------------------------------

    /** 删除一条主档；被引用、无权限、已被删除都抛出给人看的原因，不留半截状态。 */
    @Transactional
    public void delete(MasterEntityKind kind, UUID id) {
        CurrentAuthorityGuard.requireAll(kind.deletePermission());
        MasterBatchResult result = deleteInternal(kind, List.of(new MasterBatchRequests.Item(id, null)));
        MasterBatchResult.ItemResult only = result.results().getFirst();
        if (only.ok()) return;
        if (only.label() == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, kind.noun() + "不存在");
        }
        throw new ApiException(ErrorCode.CONFLICT, only.reason());
    }

    // ---- 批量命令 -----------------------------------------------------------------

    /** 批量删除：逐条授权 + 版本 + 引用保护，放行的一条 UPDATE 软删。 */
    @Transactional
    public MasterBatchResult batchDelete(MasterEntityKind kind, List<MasterBatchRequests.Item> items) {
        CurrentAuthorityGuard.requireAll(kind.deletePermission());
        return deleteInternal(kind, items);
    }

    /** 批量启用/停用：逐条授权 + 版本，放行的一条 UPDATE 改状态(原本就是目标状态的不动)。 */
    @Transactional
    public MasterBatchResult batchStatus(
            MasterEntityKind kind, String status, List<MasterBatchRequests.Item> items) {
        CurrentAuthorityGuard.requireAll(kind.statusPermission());
        if (!STATUSES.contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "状态只能是「使用」或「禁用」");
        }
        tx.bind();
        Map<UUID, Long> requested = dedupe(items);
        Map<UUID, MasterBatchResult.ItemResult> results = new LinkedHashMap<>();
        List<Row> allowed = authorize(kind, requested, results);
        List<UUID> changing = new ArrayList<>();
        for (Row row : allowed) {
            if (status.equals(row.status())) {
                results.put(row.id(), new MasterBatchResult.ItemResult(
                        row.id(), row.label(), true, "原本就是「" + status + "」，未改动"));
            } else {
                changing.add(row.id());
                results.put(row.id(), new MasterBatchResult.ItemResult(row.id(), row.label(), true, null));
            }
        }
        if (!changing.isEmpty()) {
            em.createNativeQuery("UPDATE " + kind.table() + " SET status = :status, updated_at = now(), "
                            + "updated_by = " + ACTOR + versionBump(kind)
                            + " WHERE id = ANY(" + ID_ARRAY + ")")
                    .setParameter("status", status)
                    .setParameter("ids", joined(changing))
                    .executeUpdate();
        }
        return ordered(requested, results);
    }

    // ---- 分类级联 / 导入撤回用的内部入口(调用方已校验自己的权限) --------------------

    /**
     * 连同分类一起删除子树下的货品：任何一个货品还被引用就整体拒绝(列出前几个与原因)，
     * 否则先软删这些货品自己的 BOM 行，再软删货品。必须在调用方事务内。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public int cascadeDeleteGoods(Collection<UUID> goodsIds, String context) {
        return cascadeDelete(MasterEntityKind.GOODS, goodsIds, context, List.of());
    }

    /** 连同分类一起删除子树下的模具(被有效货品引用即拒绝)。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public int cascadeDeleteMoulds(Collection<UUID> mouldIds, String context) {
        return cascadeDelete(MasterEntityKind.MOULD, mouldIds, context, List.of());
    }

    /**
     * 导入撤回：本批新建的颜色/单位若已被批外的货品、BOM、单据引用就拒绝撤回；
     * {@code alsoDeletedGoods} 是同一次撤回里一起删除的货品。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public int cascadeDelete(MasterEntityKind kind, Collection<UUID> ids, String context,
                             Collection<UUID> alsoDeletedGoods) {
        Set<UUID> distinct = ids == null ? Set.of()
                : ids.stream().filter(Objects::nonNull).collect(Collectors.toCollection(LinkedHashSet::new));
        if (distinct.isEmpty()) return 0;
        tx.bind();
        List<Row> rows = lock(kind, distinct);
        List<UUID> live = rows.stream().map(Row::id).toList();
        Map<UUID, List<MasterReferenceGuard.Blocker>> blocked = kind == MasterEntityKind.GOODS
                ? guard.goodsBlockers(live)
                : guard.blockers(kind, live, alsoDeletedGoods);
        if (!blocked.isEmpty()) {
            StringBuilder message = new StringBuilder(context).append("：其中 ").append(blocked.size())
                    .append(" 个").append(kind.noun()).append("还在被使用，没有删除任何数据。");
            int shown = 0;
            for (Row row : rows) {
                List<MasterReferenceGuard.Blocker> blockers = blocked.get(row.id());
                if (blockers == null) continue;
                if (shown == CASCADE_SAMPLE_LIMIT) {
                    message.append("\n……其余 ").append(blocked.size() - shown).append(" 个未列出");
                    break;
                }
                message.append("\n").append(++shown).append(". ")
                        .append(MasterReferenceGuard.describe(kind, row.label(), blockers));
            }
            throw new ApiException(ErrorCode.CONFLICT, message.toString());
        }
        return softDelete(kind, live);
    }

    // ---- 内部 ---------------------------------------------------------------------

    private MasterBatchResult deleteInternal(MasterEntityKind kind, List<MasterBatchRequests.Item> items) {
        tx.bind();
        Map<UUID, Long> requested = dedupe(items);
        Map<UUID, MasterBatchResult.ItemResult> results = new LinkedHashMap<>();
        List<Row> allowed = authorize(kind, requested, results);
        List<UUID> candidates = allowed.stream().map(Row::id).toList();
        Map<UUID, List<MasterReferenceGuard.Blocker>> blocked = candidates.isEmpty() ? Map.of()
                : guard.blockers(kind, candidates, List.of());
        List<UUID> deleting = new ArrayList<>();
        for (Row row : allowed) {
            List<MasterReferenceGuard.Blocker> blockers = blocked.get(row.id());
            if (blockers == null) {
                deleting.add(row.id());
                results.put(row.id(), new MasterBatchResult.ItemResult(row.id(), row.label(), true, null));
            } else {
                results.put(row.id(), new MasterBatchResult.ItemResult(row.id(), row.label(), false,
                        MasterReferenceGuard.describe(kind, row.label(), blockers)));
            }
        }
        softDelete(kind, deleting);
        return ordered(requested, results);
    }

    /** 锁行 + 对象级授权 + 版本比对；失败条目直接写进 results，返回放行的行。 */
    private List<Row> authorize(MasterEntityKind kind, Map<UUID, Long> requested,
                                Map<UUID, MasterBatchResult.ItemResult> results) {
        Map<UUID, Row> rows = new LinkedHashMap<>();
        for (Row row : lock(kind, requested.keySet())) rows.put(row.id(), row);
        Predicate<UUID> writable = access.writableOwner(kind);
        List<Row> allowed = new ArrayList<>();
        for (var entry : requested.entrySet()) {
            UUID id = entry.getKey();
            Row row = rows.get(id);
            if (row == null) {
                results.put(id, new MasterBatchResult.ItemResult(id, null, false,
                        kind.noun() + "不存在或已被删除，请刷新后重试"));
            } else if (!writable.test(row.owner())) {
                // 与单条编辑一致：无权写的对象按「不存在」口径处理，不透露它归谁。
                results.put(id, new MasterBatchResult.ItemResult(id, null, false,
                        kind.noun() + "不存在或你没有修改它的权限"));
            } else if (kind.versioned() && entry.getValue() != null
                    && entry.getValue() != row.version()) {
                results.put(id, new MasterBatchResult.ItemResult(id, row.label(), false,
                        "已被他人修改，请刷新后重试"));
            } else {
                allowed.add(row);
            }
        }
        return allowed;
    }

    private List<Row> lock(MasterEntityKind kind, Collection<UUID> ids) {
        if (ids.isEmpty()) return List.of();
        String version = kind.versioned() ? "version" : "CAST(0 AS bigint)";
        String owner = MasterObjectAccess.ownerScoped(kind) ? "owner_employee_id" : "CAST(NULL AS uuid)";
        String code = kind == MasterEntityKind.UNIT || kind == MasterEntityKind.COLOR
                ? "COALESCE(name, code, '')"
                : "TRIM(COALESCE(code, '') || ' ' || COALESCE(name, ''))";
        List<Object[]> raw = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                        "SELECT id, " + version + ", " + owner + ", status, " + code
                                + " FROM " + kind.table()
                                + " WHERE id = ANY(" + ID_ARRAY + ") AND is_deleted = FALSE"
                                + " ORDER BY id FOR UPDATE")
                .setParameter("ids", joined(ids)));
        List<Row> rows = new ArrayList<>(raw.size());
        for (Object[] row : raw) {
            rows.add(new Row((UUID) row[0], ((Number) row[1]).longValue(), (UUID) row[2],
                    (String) row[3], (String) row[4]));
        }
        return rows;
    }

    private int softDelete(MasterEntityKind kind, List<UUID> ids) {
        if (ids.isEmpty()) return 0;
        if (kind == MasterEntityKind.GOODS) {
            // 父件删除，它自己的组装清单随之失效；先删 BOM 行，数据库守卫(V683)才不会把
            // 「同批一起删的父件」误当成还在用组件的有效父件。
            em.createNativeQuery("UPDATE goods_bom_items SET is_deleted = TRUE, deleted_at = now(), "
                            + "updated_at = now(), updated_by = " + ACTOR
                            + " WHERE goods_id = ANY(" + ID_ARRAY + ") AND is_deleted = FALSE")
                    .setParameter("ids", joined(ids))
                    .executeUpdate();
        }
        return em.createNativeQuery("UPDATE " + kind.table() + " SET is_deleted = TRUE, deleted_at = now(), "
                        + "updated_at = now(), updated_by = " + ACTOR + versionBump(kind)
                        + " WHERE id = ANY(" + ID_ARRAY + ") AND is_deleted = FALSE")
                .setParameter("ids", joined(ids))
                .executeUpdate();
    }

    private static String versionBump(MasterEntityKind kind) {
        return kind.versioned() ? ", version = version + 1" : "";
    }

    private static Map<UUID, Long> dedupe(List<MasterBatchRequests.Item> items) {
        Map<UUID, Long> requested = new LinkedHashMap<>();
        for (MasterBatchRequests.Item item : items == null ? List.<MasterBatchRequests.Item>of() : items) {
            if (item != null && item.id() != null) requested.putIfAbsent(item.id(), item.version());
        }
        if (requested.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先选择要处理的记录");
        }
        if (requested.size() > MasterBatchRequests.MAX_ITEMS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "一次最多处理 " + MasterBatchRequests.MAX_ITEMS + " 条，请分批操作");
        }
        return requested;
    }

    private static MasterBatchResult ordered(
            Map<UUID, Long> requested, Map<UUID, MasterBatchResult.ItemResult> results) {
        List<MasterBatchResult.ItemResult> list = new ArrayList<>(requested.size());
        for (UUID id : requested.keySet()) list.add(results.get(id));
        return MasterBatchResult.of(list);
    }

    private static String joined(Collection<UUID> ids) {
        return ids.stream().map(UUID::toString).collect(Collectors.joining(","));
    }
}
