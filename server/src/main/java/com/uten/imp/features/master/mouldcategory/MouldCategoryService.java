package com.uten.imp.features.master.mouldcategory;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.mouldcategory.dto.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

/**
 * 模具分类树 CRUD。与 {@code MaterialCategoryService} 同构：
 * 扁平查询 + Java 端 buildTree 组装；create/update 后 em.refresh 读触发器算的 path；
 * 分类 code 由服务端生成并纳入 V279 全局终身预约；旧库 code 留在备注/快照；codePrefix
 * 变更会在事务内预检并批量改写适用模具的显示编号。level 是真实深度，改父级后整棵子树
 * level 重算；所有父子和主档关系仍只使用 UUID。
 */
@Service
@RequiredArgsConstructor
public class MouldCategoryService {

    private static final String ACQUIRE_HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('MOULD_CATEGORY_HIERARCHY',0))";

    private final MouldCategoryRepository repo;
    private final MouldRepository mouldRepo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;

    @Transactional(readOnly = true)
    public List<MouldCategoryNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null);
    }

    @Transactional(readOnly = true)
    public List<MouldCategoryNode> subtree(UUID rootId) {
        requireCategory(rootId);
        return buildTree(repo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public MouldCategoryDetail detail(UUID id) {
        MouldCategory c = requireCategory(id);
        UUID parentId = c.getParent() == null ? null : c.getParent().getId();
        String parentName = c.getParent() == null ? null : c.getParent().getName();
        long childCount = repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).size();
        return new MouldCategoryDetail(c.getId(), c.getCode(), c.getRemark(),
                c.getLegacyCodeSnapshot(), c.getCodePrefix(),
                categoryCodes.effectivePrefix(CategoryDrivenCodeService.MasterType.MOULD, c.getId()).prefix(),
                c.getName(), c.getLevel(), c.getLegacyId(), parentId, parentName,
                c.getSortOrder(), buildNamePath(c), childCount, c.getVersion(),
                systemCategories.isMouldCategory(c.getId()));
    }

    /** 拼中文 name 路径（如「模具 > 冲压模」），向上走 parent 链；用于详情卡显示。
     *  不动 entity.path（物化 code 路径，DB 触发器维护，用于排序/子树查询）。 */
    private String buildNamePath(MouldCategory c) {
        if (c == null) return "";
        String n = (c.getName() != null && !c.getName().isBlank()) ? c.getName() : null;
        String up = buildNamePath(c.getParent());
        return (n == null) ? up : (up.isEmpty() ? n : up + " > " + n);
    }

    @Transactional
    public MouldCategoryDetail create(MouldCategorySaveRequest req) {
        tx.bind();
        MouldCategory c = new MouldCategory();
        c.setCode(masterCodeService.nextCode(MasterCodePrefix.MOULD_CATEGORY));
        c.setRemark(cleanRemark(req.getRemark()));
        c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        c.setName(req.getName());
        c.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            MouldCategory parent = requireCategory(req.getParentId());
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

    @Transactional
    public MouldCategoryDetail update(UUID id, MouldCategoryUpdateRequest req) {
        tx.bind();
        if (req.getParentId() != null || req.getCodePrefix() != null) {
            lockCategoryHierarchy();
        }
        MouldCategory c = requireCategory(id);
        rejectSystemCategoryMutation(c);
        OptimisticLocks.requireUpToDate(c.getVersion(), req.getVersion());
        CategoryDrivenCodeService.EffectivePrefix oldEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.MOULD, id);
        c.setName(req.getName());
        if (req.getRemark() != null) c.setRemark(cleanRemark(req.getRemark()));
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
                CategoryDrivenCodeService.MasterType.MOULD, id);
        if (!Objects.equals(oldEffective, newEffective)) {
            categoryCodes.reconcileSubtree(CategoryDrivenCodeService.MasterType.MOULD,
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
                        CategoryDrivenCodeService.MasterType.MOULD, id, requestedPrefix)
                : categoryCodes.previewForParent(
                        CategoryDrivenCodeService.MasterType.MOULD,
                        id, requestedPrefix, requestedParentId);
    }

    /** 删除预览：该分类（含自身）子树规模，供前端删父类前弹级联确认框（问题 #7）。 */
    @Transactional(readOnly = true)
    public MouldCategoryDeletePreview deletePreview(UUID id) {
        rejectSystemCategoryMutation(requireCategory(id));
        List<UUID> ids = subtreeIds(id);
        int descendantCount = ids.size() - 1; // findSubtree 含自身，后代数减 1
        long mouldCount = mouldRepo.countByCategoryIds(ids);
        return new MouldCategoryDeletePreview(id, descendantCount, mouldCount);
    }

    /**
     * 级联软删：该分类及其全部后代分类 + 子树下模具，一并 is_deleted=true。
     * 与 {@code MaterialCategoryService.delete} 同构，不再拦截「有子分类」（问题 #7：
     * 删父类需一并删光子类，而非报错要求先手动清空）。
     */
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        rejectSystemCategoryMutation(requireCategory(id));
        List<UUID> ids = subtreeIds(id);
        OffsetDateTime now = OffsetDateTime.now();
        List<MouldCategory> nodes = repo.findSubtree(id);
        for (MouldCategory c : nodes) {
            c.setDeleted(true);
            c.setDeletedAt(now);
        }
        repo.saveAll(nodes);
        if (!ids.isEmpty()) {
            mouldRepo.softDeleteByCategoryIds(ids, now);
        }
    }

    /** 收集某分类子树（含自身）的全部 id（findSubtree 已含自身、按 path 先序）。 */
    private List<UUID> subtreeIds(UUID rootId) {
        return repo.findSubtree(rootId).stream()
                .map(MouldCategory::getId)
                .toList();
    }

    /** 移动后按 parent 关系递归重算整棵子树 level/path，不依赖移动前的旧 path 排序。 */
    private void relevelSubtree(UUID rootId) {
        if (repo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "模具分类子树结构异常，无法安全移动");
        }
    }

    private void lockCategoryHierarchy() {
        em.createNativeQuery(ACQUIRE_HIERARCHY_LOCK_SQL).getSingleResult();
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<MouldCategoryNode> buildTree(List<MouldCategory> all, UUID rootId) {
        UUID systemCategoryId = systemCategories.mouldCategoryId();
        Map<UUID, MouldCategoryNode> map = new LinkedHashMap<>();
        for (MouldCategory c : all) {
            map.put(c.getId(), toNode(c, systemCategoryId));
        }
        List<MouldCategoryNode> roots = new ArrayList<>();
        for (MouldCategory c : all) {
            MouldCategoryNode node = map.get(c.getId());
            MouldCategory parent = c.getParent();
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

    private MouldCategoryNode toNode(MouldCategory c, UUID systemCategoryId) {
        MouldCategoryNode n = new MouldCategoryNode();
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

    private MouldCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "模具分类不存在"));
    }

    private void rejectSystemCategoryMutation(MouldCategory category) {
        if (systemCategories.isMouldCategory(category.getId())) {
            throw new ApiException(ErrorCode.CONFLICT, "系统未分类模具分类不可修改或删除");
        }
    }

    private static String cleanRemark(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
