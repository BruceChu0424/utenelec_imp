package com.uten.imp.legacy.migration;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.features.master.SystemMasterCategories;
import com.uten.imp.legacy.reader.LegacyCategoryRow;
import com.uten.imp.legacy.reader.LegacyCategorySource;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;

/**
 * 将 classpath 中的模具分类样例写入本地开发库。
 *
 * <p>与 {@link MaterialCategoryMigrator} 同构（拓扑序 upsert + level 重算 + 孤儿兜底），
 * 只是目标表换成 mould_categories、ItemclassID 换成 18。
 * <p>模具分类在老库为 65 个扁平根（ParentID 全为 0、无嵌套、无孤儿），迁移后即 65 个顶级根。
 * <p>该组件只在 {@code dev} profile 注册。它按 {@code legacy_id} 可重复写入，
 * 但不是正式迁移、增量追平或切流入口。
 */
@Service
@RequiredArgsConstructor
@Profile("dev")
public class MouldCategoryMigrator {

    /** 模具系列在老库 SystemItem 的 ItemclassID（货品=1、部门=5）。 */
    public static final int MOULD_ITEM_CLASS_ID = 18;

    private final LegacyCategorySource reader;
    private final MouldCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;

    /** 迁移结果。 */
    public record MigrationReport(int total, int inserted, int updated, int orphans) {}

    /** 写入模具分类开发样例（ItemclassID=18）。 */
    @Transactional
    public MigrationReport migrateMoulds() {
        return migrate(MOULD_ITEM_CLASS_ID);
    }

    /** 读取一个 classpath 分类样例，并按拓扑序写入。 */
    @Transactional
    public MigrationReport migrate(int itemClassId) {
        tx.bind();
        em.createNativeQuery("SELECT set_config('app.business_identifier_legacy_import', 'on', true)")
                .getSingleResult();
        MouldCategory uncategorizedRoot = ensureUncategorizedRoot();
        List<LegacyCategoryRow> rows = reader.readCategoryTree(itemClassId);
        if (rows.isEmpty()) {
            return new MigrationReport(0, 0, 0, 0);
        }

        Map<Integer, LegacyCategoryRow> byLegacy = new HashMap<>();
        for (LegacyCategoryRow r : rows) {
            byLegacy.put(r.legacyId(), r);
        }

        List<LegacyCategoryRow> ordered = topoSort(rows, byLegacy);

        Map<Integer, MouldCategory> migrated = new HashMap<>();
        int inserted = 0, updated = 0, orphans = 0;

        for (LegacyCategoryRow r : ordered) {
            Integer pId = r.parentLegacyId();
            boolean isRoot = pId == null || pId <= 0;
            boolean parentMissing = !isRoot && !byLegacy.containsKey(pId);

            MouldCategory parent;
            int level;
            if (isRoot) {
                parent = null;
                level = 0;
            } else if (parentMissing) {
                orphans++;
                parent = uncategorizedRoot;
                level = parent.getLevel() + 1;
            } else {
                MouldCategory p = migrated.get(pId);
                if (p == null) {   // 拓扑兜底（成环节点）
                    orphans++;
                    p = uncategorizedRoot;
                }
                parent = p;
                level = p.getLevel() + 1;
            }

            boolean exists = repo.findByLegacyId(r.legacyId()).isPresent();
            MouldCategory c = upsert(r, parent, level);
            migrated.put(r.legacyId(), c);
            if (exists) updated++; else inserted++;
        }
        return new MigrationReport(rows.size(), inserted, updated, orphans);
    }

    private MouldCategory upsert(LegacyCategoryRow r, MouldCategory parent, int level) {
        Optional<MouldCategory> existing = repo.findByLegacyId(r.legacyId());
        MouldCategory c = existing.orElseGet(() -> {
            MouldCategory n = new MouldCategory();
            n.setLegacyId(r.legacyId());
            return n;
        });
        if (existing.isEmpty()) {
            c.setCode(masterCodeService.nextCode(MasterCodePrefix.MOULD_CATEGORY));
            c.setRemark(r.code());
            c.setLegacyCodeSnapshot(r.code());
        }
        c.setName(r.name());
        c.setParent(parent);
        c.setLevel(level);
        repo.save(c);
        em.flush();   // 触发器即时算 path；保证子节点挂父时父行已入库
        return c;
    }

    /** 系统未分类根（legacy_id=-1）：始终存在，同时承接孤儿分类。 */
    private MouldCategory ensureUncategorizedRoot() {
        MouldCategory root = repo.findByLegacyId(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID)
                .orElseGet(() -> {
            MouldCategory created = new MouldCategory();
            created.setLegacyId(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID);
            return created;
        });
        root.setCode(SystemMasterCategories.MOULD_CODE);
        root.setRemark(SystemMasterCategories.SYSTEM_REMARK);
        root.setLegacyCodeSnapshot(SystemMasterCategories.SYSTEM_REMARK);
        root.setCodePrefix(null);
        root.setName(SystemMasterCategories.UNCATEGORIZED_NAME);
        root.setParent(null);
        root.setLevel(0);
        root.setSortOrder(Integer.MAX_VALUE);
        root.setDeleted(false);
        root.setDeletedAt(null);
        root = repo.save(root);
        em.flush();
        return root;
    }

    /** Kahn 拓扑排序：根（ParentID≤0 或父不在集合）在前，父先于子。成环节点兜底追加。 */
    private List<LegacyCategoryRow> topoSort(List<LegacyCategoryRow> rows,
                                             Map<Integer, LegacyCategoryRow> byLegacy) {
        Map<Integer, Integer> inDegree = new HashMap<>();
        Map<Integer, List<Integer>> children = new HashMap<>();
        for (LegacyCategoryRow r : rows) {
            inDegree.putIfAbsent(r.legacyId(), 0);
            children.computeIfAbsent(r.legacyId(), k -> new ArrayList<>());
        }
        for (LegacyCategoryRow r : rows) {
            Integer p = r.parentLegacyId();
            if (p != null && p > 0 && byLegacy.containsKey(p)) {
                children.get(p).add(r.legacyId());
                inDegree.merge(r.legacyId(), 1, Integer::sum);
            }
        }
        Deque<Integer> queue = new ArrayDeque<>();
        for (Map.Entry<Integer, Integer> e : inDegree.entrySet()) {
            if (e.getValue() == 0) queue.add(e.getKey());
        }
        List<LegacyCategoryRow> result = new ArrayList<>(rows.size());
        Set<Integer> processed = new HashSet<>();
        while (!queue.isEmpty()) {
            Integer id = queue.poll();
            LegacyCategoryRow r = byLegacy.get(id);
            if (r != null) {
                result.add(r);
                processed.add(id);
            }
            for (Integer ch : children.getOrDefault(id, List.of())) {
                if (inDegree.merge(ch, -1, Integer::sum) == 0) queue.add(ch);
            }
        }
        if (result.size() < rows.size()) {
            for (LegacyCategoryRow r : rows) {   // 成环节点兜底（将被当孤儿）
                if (!processed.contains(r.legacyId())) result.add(r);
            }
        }
        return result;
    }
}
