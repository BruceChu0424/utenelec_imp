package com.uten.imp.features.master.clientcategory;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.clientcategory.dto.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

/**
 * 客户分类树 CRUD。仿 {@link com.uten.imp.features.master.materialcategory.MaterialCategoryService}：
 * 扁平查询 + Java 端 buildTree 组装；create/update 后 em.refresh 读触发器算的 path；
 * 分类 code 由服务端生成并纳入 V279 全局终身预约；旧库 code 留在备注/快照；codePrefix
 * 变更会在事务内预检并批量改写适用客户的显示编号。level 是真实深度，改父级后整棵子树
 * level 重算；所有父子和主档关系仍只使用 UUID。
 */
@Service
@RequiredArgsConstructor
public class ClientCategoryService {

    private static final String ACQUIRE_HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('CLIENT_CATEGORY_HIERARCHY',0))";

    private final ClientCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;

    @Transactional(readOnly = true)
    public List<ClientCategoryNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null);
    }

    @Transactional(readOnly = true)
    public List<ClientCategoryNode> subtree(UUID rootId) {
        requireCategory(rootId);
        return buildTree(repo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public ClientCategoryDetail detail(UUID id) {
        ClientCategory c = requireCategory(id);
        UUID parentId = c.getParent() == null ? null : c.getParent().getId();
        String parentName = c.getParent() == null ? null : c.getParent().getName();
        long childCount = repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).size();
        return new ClientCategoryDetail(c.getId(), c.getCode(), c.getRemark(),
                c.getLegacyCodeSnapshot(), c.getCodePrefix(),
                categoryCodes.effectivePrefix(CategoryDrivenCodeService.MasterType.CLIENT, c.getId()).prefix(),
                c.getName(), c.getLevel(), c.getLegacyId(), parentId, parentName,
                c.getSortOrder(), buildNamePath(c), childCount, c.getVersion(),
                systemCategories.isClientCategory(c.getId()));
    }

    /** 拼中文 name 路径，向上走 parent 链；用于详情卡显示。
     *  不动 entity.path（物化 code 路径，DB 触发器维护，用于排序/子树查询）。 */
    private String buildNamePath(ClientCategory c) {
        if (c == null) return "";
        String n = (c.getName() != null && !c.getName().isBlank()) ? c.getName() : null;
        String up = buildNamePath(c.getParent());
        return (n == null) ? up : (up.isEmpty() ? n : up + " > " + n);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client_category:create')")
    @Transactional
    public ClientCategoryDetail create(ClientCategorySaveRequest req) {
        tx.bind();
        ClientCategory c = new ClientCategory();
        c.setCode(masterCodeService.nextCode(MasterCodePrefix.CLIENT_CATEGORY));
        c.setRemark(cleanRemark(req.getRemark()));
        c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        c.setName(req.getName());
        c.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            ClientCategory parent = requireCategory(req.getParentId());
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

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('client_category:edit', 'client_category:move', 'client_category:reorder')")
    @Transactional
    public ClientCategoryDetail update(UUID id, ClientCategoryUpdateRequest req) {
        tx.bind();
        boolean moveToRoot = Boolean.TRUE.equals(req.getMoveToRoot());
        if (moveToRoot && req.getParentId() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "parentId 与 moveToRoot 不能同时提交");
        }
        if (req.getParentId() != null || moveToRoot || req.getCodePrefix() != null) {
            lockCategoryHierarchy();
        }
        ClientCategory c = requireCategory(id);
        rejectSystemCategoryMutation(c);
        OptimisticLocks.requireUpToDate(c.getVersion(), req.getVersion());
        CategoryDrivenCodeService.EffectivePrefix oldEffective = categoryCodes.effectivePrefix(
                CategoryDrivenCodeService.MasterType.CLIENT, id);
        boolean editChanged = !Objects.equals(c.getName(), req.getName())
                || (req.getRemark() != null
                    && !Objects.equals(c.getRemark(), cleanRemark(req.getRemark())))
                || (req.getCodePrefix() != null
                    && !Objects.equals(c.getCodePrefix(),
                        CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix())));
        if (editChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("client_category:edit");
        }
        c.setName(req.getName());
        if (req.getRemark() != null) c.setRemark(cleanRemark(req.getRemark()));
        if (req.getCodePrefix() != null) {
            c.setCodePrefix(CategoryDrivenCodeService.normalizePrefix(req.getCodePrefix()));
        }
        if (req.getSortOrder() != null
                && !Objects.equals(c.getSortOrder(), req.getSortOrder())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("client_category:reorder");
            c.setSortOrder(req.getSortOrder());
        }
        UUID currentParentId = c.getParent() == null ? null : c.getParent().getId();
        UUID requestedParentId = moveToRoot ? null : req.getParentId();
        boolean parentChanged = moveToRoot
                ? currentParentId != null
                : requestedParentId != null && !requestedParentId.equals(currentParentId);
        if (parentChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("client_category:move");
            if (requestedParentId == null) {
                c.setParent(null);
            } else {
                if (requestedParentId.equals(id)) {
                    throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
                }
                if (repo.isDescendant(id, requestedParentId)) {
                    throw new ApiException(ErrorCode.CONFLICT, "不能将分类挂到其子分类下（会成环）");
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
                CategoryDrivenCodeService.MasterType.CLIENT, id);
        if (!Objects.equals(oldEffective, newEffective)) {
            categoryCodes.reconcileSubtree(CategoryDrivenCodeService.MasterType.CLIENT,
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
                        CategoryDrivenCodeService.MasterType.CLIENT, id, requestedPrefix)
                : categoryCodes.previewForParent(
                        CategoryDrivenCodeService.MasterType.CLIENT,
                        id, requestedPrefix, requestedParentId);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client_category:delete')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        ClientCategory c = requireCategory(id);
        rejectSystemCategoryMutation(c);
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该分类的子分类");
        }
        Number activeClients = (Number) em.createNativeQuery("""
                SELECT count(*) FROM clients
                WHERE category_id = :categoryId AND is_deleted = false
                """)
                .setParameter("categoryId", id)
                .getSingleResult();
        if (activeClients.longValue() > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该分类下仍有客户，不能删除");
        }
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    /** 移动后按 parent 关系递归重算整棵子树 level/path，不依赖移动前的旧 path 排序。 */
    private void relevelSubtree(UUID rootId) {
        if (repo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "客户分类子树结构异常，无法安全移动");
        }
    }

    private void lockCategoryHierarchy() {
        em.createNativeQuery(ACQUIRE_HIERARCHY_LOCK_SQL).getSingleResult();
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<ClientCategoryNode> buildTree(List<ClientCategory> all, UUID rootId) {
        UUID systemCategoryId = systemCategories.clientCategoryId();
        Map<UUID, ClientCategoryNode> map = new LinkedHashMap<>();
        for (ClientCategory c : all) {
            map.put(c.getId(), toNode(c, systemCategoryId));
        }
        List<ClientCategoryNode> roots = new ArrayList<>();
        for (ClientCategory c : all) {
            ClientCategoryNode node = map.get(c.getId());
            ClientCategory parent = c.getParent();
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

    private ClientCategoryNode toNode(ClientCategory c, UUID systemCategoryId) {
        ClientCategoryNode n = new ClientCategoryNode();
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

    private ClientCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户分类不存在"));
    }

    private void rejectSystemCategoryMutation(ClientCategory category) {
        if (systemCategories.isClientCategory(category.getId())) {
            throw new ApiException(ErrorCode.CONFLICT, "系统未分类客户分类不可修改或删除");
        }
    }

    private static String cleanRemark(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
