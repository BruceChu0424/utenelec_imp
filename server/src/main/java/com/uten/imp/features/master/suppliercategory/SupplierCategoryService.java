package com.uten.imp.features.master.suppliercategory;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.suppliercategory.dto.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

/**
 * 供应商分类树 CRUD。仿 {@link com.uten.imp.features.master.materialcategory.MaterialCategoryService}：
 * 扁平查询 + Java 端 buildTree 组装；create/update 后 em.refresh 读触发器算的 path；
 * 分类 code 由服务端生成并纳入 V279 全局终身预约；旧库 code 留在备注/快照；codePrefix
 * 变更会在事务内预检并批量改写适用供应商的显示编号。level 是真实深度，改父级后整棵子树
 * level 重算；所有父子和主档关系仍只使用 UUID。
 */
@Service
@RequiredArgsConstructor
public class SupplierCategoryService {

    private static final String ACQUIRE_HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('SUPPLIER_CATEGORY_HIERARCHY',0))";

    private final SupplierCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;

    @Transactional(readOnly = true)
    public List<SupplierCategoryNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null);
    }

    @Transactional(readOnly = true)
    public List<SupplierCategoryNode> subtree(UUID rootId) {
        requireCategory(rootId);
        return buildTree(repo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public SupplierCategoryDetail detail(UUID id) {
        SupplierCategory c = requireCategory(id);
        UUID parentId = c.getParent() == null ? null : c.getParent().getId();
        String parentName = c.getParent() == null ? null : c.getParent().getName();
        long childCount = repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).size();
        return new SupplierCategoryDetail(c.getId(), c.getCode(), c.getRemark(),
                c.getLegacyCodeSnapshot(), c.getCodePrefix(),
                categoryCodes.effectivePrefix(CategoryDrivenCodeService.MasterType.SUPPLIER, c.getId()).prefix(),
                c.getName(), c.getLevel(), c.getLegacyId(), parentId, parentName,
                c.getSortOrder(), buildNamePath(c), childCount, c.getVersion(),
                systemCategories.isSupplierCategory(c.getId()));
    }

    /** 拼中文 name 路径，向上走 parent 链；用于详情卡显示。
     *  不动 entity.path（物化 code 路径，DB 触发器维护，用于排序/子树查询）。 */
    private String buildNamePath(SupplierCategory c) {
        if (c == null) return "";
        String n = (c.getName() != null && !c.getName().isBlank()) ? c.getName() : null;
        String up = buildNamePath(c.getParent());
        return (n == null) ? up : (up.isEmpty() ? n : up + " > " + n);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('supplier_category:create')")
    @Transactional
    public SupplierCategoryDetail create(SupplierCategorySaveRequest req) {
        tx.bind();
        SupplierCategory c = new SupplierCategory();
        c.setCode(masterCodeService.nextCode(MasterCodePrefix.SUPPLIER_CATEGORY));
        c.setRemark(cleanRemark(req.getRemark()));
        c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        c.setName(req.getName());
        c.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            SupplierCategory parent = requireCategory(req.getParentId());
            c.setParent(parent);
            c.setLevel(parent.getLevel() + 1);
        } else {
            c.setLevel(0);
        }
        c = repo.save(c); // UUID 构造时赋值→isNew=false→save 走 merge 返回托管副本；用返回值，否则 em.refresh(游离 c) 报 "Entity not managed"
        em.flush();
        em.refresh(c);   // 触发器算 path 后刷新
        return detail(c.getId());
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('supplier_category:edit', 'supplier_category:move', 'supplier_category:reorder')")
    @Transactional
    public SupplierCategoryDetail update(UUID id, SupplierCategoryUpdateRequest req) {
        tx.bind();
        boolean moveToRoot = Boolean.TRUE.equals(req.getMoveToRoot());
        if (moveToRoot && req.getParentId() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "parentId 与 moveToRoot 不能同时提交");
        }
        if (req.getParentId() != null || moveToRoot || req.getCodePrefix() != null) {
            lockCategoryHierarchy();
        }
        SupplierCategory c = requireCategory(id);
        rejectSystemCategoryMutation(c);
        OptimisticLocks.requireUpToDate(c.getVersion(), req.getVersion());
        CategoryDrivenCodeService.EffectivePrefix oldEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.SUPPLIER, id);
        boolean editChanged = !Objects.equals(c.getName(), req.getName())
                || (req.getRemark() != null
                    && !Objects.equals(c.getRemark(), cleanRemark(req.getRemark())))
                || (req.getCodePrefix() != null
                    && !Objects.equals(c.getCodePrefix(),
                        CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix())));
        if (editChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier_category:edit");
        }
        c.setName(req.getName());
        if (req.getRemark() != null) c.setRemark(cleanRemark(req.getRemark()));
        if (req.getCodePrefix() != null) {
            c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        }
        if (req.getSortOrder() != null
                && !Objects.equals(c.getSortOrder(), req.getSortOrder())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier_category:reorder");
            c.setSortOrder(req.getSortOrder());
        }
        UUID currentParentId = c.getParent() == null ? null : c.getParent().getId();
        UUID requestedParentId = moveToRoot ? null : req.getParentId();
        boolean parentChanged = moveToRoot
                ? currentParentId != null
                : requestedParentId != null && !requestedParentId.equals(currentParentId);
        if (parentChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier_category:move");
            if (requestedParentId == null) {
                c.setParent(null);
            } else {
                if (requestedParentId.equals(id)) {
                    throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
                }
                if (repo.isDescendant(id, requestedParentId)) {
                    throw new ApiException(ErrorCode.CONFLICT, "不能将分类挂到其子分类下(会成环)");
                }
                c.setParent(requireCategory(requestedParentId));
            }
        }
        repo.save(c);
        em.flush();
        em.refresh(c);
        if (parentChanged) {
            relevelSubtree(id);   // level 是真实深度，移动后整棵子树重算
        }
        CategoryDrivenCodeService.EffectivePrefix newEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.SUPPLIER, id);
        if (!Objects.equals(oldEffective, newEffective)) {
            categoryCodes.reconcileSubtree(CategoryDrivenCodeService.MasterType.SUPPLIER,
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
                        CategoryDrivenCodeService.MasterType.SUPPLIER, id, requestedPrefix)
                : categoryCodes.previewForParent(
                        CategoryDrivenCodeService.MasterType.SUPPLIER,
                        id, requestedPrefix, requestedParentId);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('supplier_category:delete')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SupplierCategory c = requireCategory(id);
        rejectSystemCategoryMutation(c);
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该分类的子分类");
        }
        Number activeSuppliers = (Number) em.createNativeQuery("""
                SELECT count(*) FROM suppliers
                WHERE category_id = :categoryId AND is_deleted = false
                """)
                .setParameter("categoryId", id)
                .getSingleResult();
        if (activeSuppliers.longValue() > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该分类下仍有供应商，不能删除");
        }
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    /** 移动后按 parent 关系递归重算整棵子树 level/path，不依赖移动前的旧 path 排序。 */
    private void relevelSubtree(UUID rootId) {
        if (repo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "供应商分类子树结构异常，无法安全移动");
        }
    }

    private void lockCategoryHierarchy() {
        em.createNativeQuery(ACQUIRE_HIERARCHY_LOCK_SQL).getSingleResult();
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<SupplierCategoryNode> buildTree(List<SupplierCategory> all, UUID rootId) {
        UUID systemCategoryId = systemCategories.supplierCategoryId();
        Map<UUID, SupplierCategoryNode> map = new LinkedHashMap<>();
        for (SupplierCategory c : all) {
            map.put(c.getId(), toNode(c, systemCategoryId));
        }
        List<SupplierCategoryNode> roots = new ArrayList<>();
        for (SupplierCategory c : all) {
            SupplierCategoryNode node = map.get(c.getId());
            SupplierCategory parent = c.getParent();
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

    private SupplierCategoryNode toNode(SupplierCategory c, UUID systemCategoryId) {
        SupplierCategoryNode n = new SupplierCategoryNode();
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

    private SupplierCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商分类不存在"));
    }

    private void rejectSystemCategoryMutation(SupplierCategory category) {
        if (systemCategories.isSupplierCategory(category.getId())) {
            throw new ApiException(ErrorCode.CONFLICT, "系统未分类供应商分类不可修改或删除");
        }
    }

    private static String cleanRemark(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
