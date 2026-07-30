package com.uten.imp.features.master.clientcategory;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
 * code 不查重；level 是真实深度，改父级后整棵子树 level 重算。
 */
@Service
@RequiredArgsConstructor
public class ClientCategoryService {

    private final ClientCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<ClientCategoryNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderById(), null);
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
        return new ClientCategoryDetail(c.getId(), c.getCode(), c.getName(), c.getLevel(),
                c.getLegacyId(), parentId, parentName, c.getSortOrder(), c.getPath(), childCount);
    }

    @Transactional
    public ClientCategoryDetail create(ClientCategorySaveRequest req) {
        tx.bind();
        ClientCategory c = new ClientCategory();
        c.setCode(req.getCode());
        c.setName(req.getName());
        c.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            ClientCategory parent = requireCategory(req.getParentId());
            c.setParent(parent);
            c.setLevel(parent.getLevel() + 1);
        } else {
            c.setLevel(0);
        }
        repo.save(c);
        em.flush();
        em.refresh(c);   // 触发器算 path 后刷新
        return detail(c.getId());
    }

    @Transactional
    public ClientCategoryDetail update(UUID id, ClientCategoryUpdateRequest req) {
        tx.bind();
        ClientCategory c = requireCategory(id);
        c.setName(req.getName());
        if (req.getSortOrder() != null) {
            c.setSortOrder(req.getSortOrder());
        }
        boolean parentChanged = false;
        if (req.getParentId() != null) {
            if (req.getParentId().equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (repo.isDescendant(id, req.getParentId())) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将分类挂到其子分类下（会成环）");
            }
            c.setParent(requireCategory(req.getParentId()));
            parentChanged = true;
        }
        repo.save(c);
        em.flush();
        em.refresh(c);
        if (parentChanged) {
            relevelSubtree(id);   // level 是真实深度，移动后整棵子树重算
        }
        return detail(id);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        ClientCategory c = requireCategory(id);
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该分类的子分类");
        }
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    /** 改父级后重算子树 level（findSubtree 按 path 排序，父先于子）。 */
    private void relevelSubtree(UUID rootId) {
        List<ClientCategory> nodes = repo.findSubtree(rootId);
        Map<UUID, Integer> levelById = new HashMap<>();
        for (ClientCategory c : nodes) {
            int lvl = c.getParent() == null ? 0 : levelById.getOrDefault(c.getParent().getId(), 0) + 1;
            c.setLevel(lvl);
            levelById.put(c.getId(), lvl);
        }
        repo.saveAll(nodes);
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<ClientCategoryNode> buildTree(List<ClientCategory> all, UUID rootId) {
        Map<UUID, ClientCategoryNode> map = new LinkedHashMap<>();
        for (ClientCategory c : all) {
            map.put(c.getId(), toNode(c));
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

    private ClientCategoryNode toNode(ClientCategory c) {
        ClientCategoryNode n = new ClientCategoryNode();
        n.setId(c.getId());
        n.setCode(c.getCode());
        n.setName(c.getName());
        n.setLevel(c.getLevel());
        n.setParentId(c.getParent() == null ? null : c.getParent().getId());
        n.setSortOrder(c.getSortOrder());
        n.setLegacyId(c.getLegacyId());
        return n;
    }

    private ClientCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户分类不存在"));
    }
}
