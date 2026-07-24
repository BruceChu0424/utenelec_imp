package com.uten.imp.legacy.migration;

import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.legacy.reader.LegacyCategoryRow;
import com.uten.imp.legacy.reader.LegacyCategorySource;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;

/**
 * 老库 SystemItem（货品分类，ItemclassID=1）→ 新库 material_categories 迁移。
 *
 * <p><b>幂等 + 增量</b>：按 legacy_id upsert，可反复重跑；老库新增的分类下次自动纳入。
 * <p><b>数据坑处理</b>（见 docs/06-老系统融合/06-货品资料分类树-老库溯源.md）：
 * <ul>
 *   <li>Number 重复 → code 不查重，定位用 legacy_id</li>
 *   <li>Level 不可靠 → 按 parent 链重算真实深度</li>
 *   <li>15 个孤儿（父被删）→ 挂虚拟根 legacy_id=-1「未分类（历史孤儿）」</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class MaterialCategoryMigrator {

    /** 货品分类在老库 SystemItem 的 ItemclassID（模具=18、部门=5 复用本迁移）。 */
    public static final int GOODS_ITEM_CLASS_ID = 1;

    private static final int ORPHAN_ROOT_LEGACY_ID = -1;
    private static final String ORPHAN_ROOT_CODE = "LEGACY_ORPHAN";
    private static final String ORPHAN_ROOT_NAME = "未分类（历史孤儿）";

    private final LegacyCategorySource reader;
    private final MaterialCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;

    /** 迁移结果。 */
    public record MigrationReport(int total, int inserted, int updated, int orphans) {}

    /** 迁货品分类（ItemclassID=1）。前端/运维直接调用的入口。 */
    @Transactional
    public MigrationReport migrateGoods() {
        return migrate(GOODS_ITEM_CLASS_ID);
    }

    /** 通用迁移：读老库某 ItemclassID 的分类树，按拓扑序 upsert。 */
    @Transactional
    public MigrationReport migrate(int itemClassId) {
        tx.bind();
        List<LegacyCategoryRow> rows = reader.readCategoryTree(itemClassId);
        if (rows.isEmpty()) {
            return new MigrationReport(0, 0, 0, 0);
        }

        Map<Integer, LegacyCategoryRow> byLegacy = new HashMap<>();
        for (LegacyCategoryRow r : rows) {
            byLegacy.put(r.legacyId(), r);
        }

        List<LegacyCategoryRow> ordered = topoSort(rows, byLegacy);

        Map<Integer, MaterialCategory> migrated = new HashMap<>();
        int inserted = 0, updated = 0, orphans = 0;

        for (LegacyCategoryRow r : ordered) {
            Integer pId = r.parentLegacyId();
            boolean isRoot = pId == null || pId <= 0;
            boolean parentMissing = !isRoot && !byLegacy.containsKey(pId);

            MaterialCategory parent;
            int level;
            if (isRoot) {
                parent = null;
                level = 0;
            } else if (parentMissing) {
                orphans++;
                parent = ensureOrphanRoot();
                level = parent.getLevel() + 1;
            } else {
                MaterialCategory p = migrated.get(pId);
                if (p == null) {   // 拓扑兜底（成环节点）
                    orphans++;
                    p = ensureOrphanRoot();
                }
                parent = p;
                level = p.getLevel() + 1;
            }

            boolean exists = repo.findByLegacyId(r.legacyId()).isPresent();
            MaterialCategory c = upsert(r, parent, level);
            migrated.put(r.legacyId(), c);
            if (exists) updated++; else inserted++;
        }
        return new MigrationReport(rows.size(), inserted, updated, orphans);
    }

    private MaterialCategory upsert(LegacyCategoryRow r, MaterialCategory parent, int level) {
        MaterialCategory c = repo.findByLegacyId(r.legacyId()).orElseGet(() -> {
            MaterialCategory n = new MaterialCategory();
            n.setLegacyId(r.legacyId());
            return n;
        });
        c.setCode(r.code());
        c.setName(r.name());
        c.setParent(parent);
        c.setLevel(level);
        repo.save(c);
        em.flush();   // 触发器即时算 path；保证子节点挂父时父行已入库
        return c;
    }

    /** 虚拟孤儿根（legacy_id=-1）：首次创建后复用，保证多次迁移指向同一根。 */
    private MaterialCategory ensureOrphanRoot() {
        return repo.findByLegacyId(ORPHAN_ROOT_LEGACY_ID).orElseGet(() -> {
            MaterialCategory root = new MaterialCategory();
            root.setLegacyId(ORPHAN_ROOT_LEGACY_ID);
            root.setCode(ORPHAN_ROOT_CODE);
            root.setName(ORPHAN_ROOT_NAME);
            root.setLevel(0);
            repo.save(root);
            em.flush();
            return root;
        });
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
