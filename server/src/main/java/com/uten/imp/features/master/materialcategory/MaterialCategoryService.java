package com.uten.imp.features.master.materialcategory;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.materialcategory.dto.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

/**
 * 物料分类树 CRUD。仿 {@link com.uten.imp.features.org.department.DepartmentService}：
 * 扁平查询 + Java 端 buildTree 组装；create/update 后 em.refresh 读触发器算的 path；
 * 与部门的差异：分类 code 由服务端生成并纳入 V279 全局终身预约；旧库 code 留在备注/快照；
 * codePrefix 变更会在事务内预检并批量改写适用主档的显示编号。level 是真实深度，改父级后
 * 整棵子树 level 重算；所有父子和主档关系仍只使用 UUID。
 */
@Service
@RequiredArgsConstructor
public class MaterialCategoryService {

    private static final String ACQUIRE_HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('MATERIAL_CATEGORY_HIERARCHY',0))";

    private final MaterialCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;

    @Transactional(readOnly = true)
    public List<MaterialCategoryNode> tree() {
        UUID systemCategoryId = systemCategories.materialCategoryId();
        return buildTree(
                repo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null, systemCategoryId);
    }

    @Transactional(readOnly = true)
    public List<MaterialCategoryNode> subtree(UUID rootId) {
        requireCategory(rootId);
        UUID systemCategoryId = systemCategories.materialCategoryId();
        return buildTree(repo.findSubtree(rootId), rootId, systemCategoryId);
    }

    @Transactional(readOnly = true)
    public MaterialCategoryDetail detail(UUID id) {
        MaterialCategory c = requireCategory(id);
        UUID parentId = c.getParent() == null ? null : c.getParent().getId();
        String parentName = c.getParent() == null ? null : c.getParent().getName();
        long childCount = repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).size();
        return new MaterialCategoryDetail(c.getId(), c.getCode(), c.getRemark(),
                c.getLegacyCodeSnapshot(), c.getCodePrefix(),
                categoryCodes.effectivePrefix(CategoryDrivenCodeService.MasterType.GOODS, c.getId()).prefix(),
                c.getName(), c.getLevel(), c.getLegacyId(), parentId, parentName,
                c.getSortOrder(), buildNamePath(c), childCount, c.getVersion(),
                systemCategories.isMaterialCategory(c.getId()));
    }

    /** 拼中文 name 路径（如「原材料 > 钢材」），向上走 parent 链；用于详情卡显示。
     *  不动 entity.path（物化 code 路径，DB 触发器维护，用于排序/子树查询）。 */
    private String buildNamePath(MaterialCategory c) {
        if (c == null) return "";
        String n = (c.getName() != null && !c.getName().isBlank()) ? c.getName() : null;
        String up = buildNamePath(c.getParent());
        return (n == null) ? up : (up.isEmpty() ? n : up + " > " + n);
    }

    @Transactional
    public MaterialCategoryDetail create(MaterialCategorySaveRequest req) {
        tx.bind();
        MaterialCategory c = new MaterialCategory();
        // 分类自身的内部 code 只用于兼容 path；用户可编辑的是 remark 和 codePrefix。
        c.setCode(masterCodeService.nextCode(MasterCodePrefix.CATEGORY));
        c.setRemark(cleanRemark(req.getRemark()));
        c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        c.setName(req.getName());
        c.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            MaterialCategory parent = requireCategory(req.getParentId());
            c.setParent(parent);
            c.setLevel(parent.getLevel() + 1);
        } else {
            c.setLevel(0);
        }
        // UUID 在构造时即赋值（BaseEntity.id=UUID.randomUUID()）→ Spring Data 判定 isNew=false
        // → save 走 em.merge，返回新的托管副本、原 c 仍游离。必须用返回值，否则下面
        // em.refresh(游离 c) 会抛 "Entity not managed"（此 bug 此前被 master_code_sequences 缺表挡住未暴露）。
        c = repo.save(c);
        em.flush();
        em.refresh(c);   // 触发器算 path 后刷新
        return detail(c.getId());
    }

    @Transactional
    public MaterialCategoryDetail update(UUID id, MaterialCategoryUpdateRequest req) {
        tx.bind();
        if (req.getParentId() != null || req.getCodePrefix() != null) {
            lockCategoryHierarchy();
        }
        MaterialCategory c = requireCategory(id);
        requireMutableCategory(c.getId());
        OptimisticLocks.requireUpToDate(c.getVersion(), req.getVersion());
        CategoryDrivenCodeService.EffectivePrefix oldEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.GOODS, id);
        c.setName(req.getName());
        if (req.getRemark() != null) {
            c.setRemark(cleanRemark(req.getRemark()));
        }
        if (req.getCodePrefix() != null) {
            c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        }
        if (req.getSortOrder() != null) {
            c.setSortOrder(req.getSortOrder());
        }
        UUID currentParentId = c.getParent() == null ? null : c.getParent().getId();
        UUID requestedParentId = req.getParentId();
        boolean parentChanged = requestedParentId != null
                && !requestedParentId.equals(currentParentId);
        if (parentChanged) {
            if (requestedParentId.equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (repo.isDescendant(id, requestedParentId)) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将分类挂到其子分类下（会成环）");
            }
            c.setParent(requireCategory(requestedParentId));
        }
        repo.save(c);
        em.flush();
        em.refresh(c);
        if (parentChanged) {
            relevelSubtree(id);   // level 是真实深度，移动后整棵子树重算
        }
        CategoryDrivenCodeService.EffectivePrefix newEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.GOODS, id);
        if (!Objects.equals(oldEffective, newEffective)) {
            categoryCodes.reconcileSubtree(CategoryDrivenCodeService.MasterType.GOODS,
                    id, oldEffective.prefix(), c.getCodePrefix());
        }
        return detail(id);
    }

    @Transactional(readOnly = true)
    public CategoryPrefixPreview prefixPreview(
            UUID id, String requestedPrefix, UUID requestedParentId) {
        requireCategory(id);
        return requestedParentId == null
                ? categoryCodes.preview(
                        CategoryDrivenCodeService.MasterType.GOODS, id, requestedPrefix)
                : categoryCodes.previewForParent(
                        CategoryDrivenCodeService.MasterType.GOODS,
                        id, requestedPrefix, requestedParentId);
    }

    @Transactional(readOnly = true)
    public MaterialCategoryDeletePreview deletePreview(UUID id) {
        requireCategory(id);
        List<UUID> ids = subtreeIds(id);
        int descendantCount = ids.size() - 1; // findSubtree 含自身，后代数减 1
        long goodsCount = repo.countGoodsByCategoryIds(ids);
        return new MaterialCategoryDeletePreview(id, descendantCount, goodsCount);
    }

    /**
     * 级联软删：该分类及其全部后代分类 + 子树下货品，一并 is_deleted=true。
     *
     * <p>不再拦截「有子分类」——父分类可直接删，整棵子树随之软删；子树下的货品也一并软删
     * （单据/报表 JOIN goods 仅按 id 关联、不过滤 is_deleted，故历史单据货品名仍可解析；
     * 软删只是把它们从货品资料页/选择器隐藏）。
     */
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        requireCategory(id);
        requireMutableCategory(id);
        List<UUID> ids = subtreeIds(id);
        OffsetDateTime now = OffsetDateTime.now();
        // 软删整棵子树分类（含自身）。
        List<MaterialCategory> nodes = repo.findSubtree(id);
        for (MaterialCategory c : nodes) {
            c.setDeleted(true);
            c.setDeletedAt(now);
        }
        repo.saveAll(nodes);
        // 软删子树下货品（若有）。bulk update 绕过持久上下文，但本事务内无后续读这些 goods，安全。
        if (!ids.isEmpty()) {
            repo.softDeleteGoodsByCategoryIds(ids, now);
        }
    }

    /** 收集某分类子树（含自身）的全部 id（findSubtree 已含自身、按 path 先序）。 */
    private List<UUID> subtreeIds(UUID rootId) {
        return repo.findSubtree(rootId).stream()
                .map(MaterialCategory::getId)
                .toList();
    }

    /** 移动后按 parent 关系递归重算整棵子树 level/path，不依赖移动前的旧 path 排序。 */
    private void relevelSubtree(UUID rootId) {
        if (repo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "物料分类子树结构异常，无法安全移动");
        }
    }

    private void lockCategoryHierarchy() {
        em.createNativeQuery(ACQUIRE_HIERARCHY_LOCK_SQL).getSingleResult();
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<MaterialCategoryNode> buildTree(
            List<MaterialCategory> all, UUID rootId, UUID systemCategoryId) {
        Map<UUID, MaterialCategoryNode> map = new LinkedHashMap<>();
        for (MaterialCategory c : all) {
            map.put(c.getId(), toNode(c, systemCategoryId));
        }
        List<MaterialCategoryNode> roots = new ArrayList<>();
        for (MaterialCategory c : all) {
            MaterialCategoryNode node = map.get(c.getId());
            MaterialCategory parent = c.getParent();
            if (parent == null || !map.containsKey(parent.getId())) {
                if (rootId == null || c.getId().equals(rootId)) {
                    roots.add(node);
                }
            } else {
                map.get(parent.getId()).getChildren().add(node);
            }
        }
        return roots;
    }

    private MaterialCategoryNode toNode(MaterialCategory c, UUID systemCategoryId) {
        MaterialCategoryNode n = new MaterialCategoryNode();
        n.setId(c.getId());
        n.setCode(c.getCode());
        n.setRemark(c.getRemark());
        n.setCodePrefix(c.getCodePrefix());
        n.setName(c.getName());
        n.setLevel(c.getLevel());
        n.setParentId(c.getParent() == null ? null : c.getParent().getId());
        n.setSortOrder(c.getSortOrder());
        n.setLegacyId(c.getLegacyId());
        n.setSystemManaged(c.getId().equals(systemCategoryId));
        return n;
    }

    private void requireMutableCategory(UUID id) {
        if (systemCategories.isMaterialCategory(id)) {
            throw new ApiException(ErrorCode.CONFLICT, "系统未分类根不能编辑或删除");
        }
    }

    private MaterialCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "物料分类不存在"));
    }

    private static String cleanRemark(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
