package com.uten.imp.features.master.suppliercategory;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
 * code 不查重；level 是真实深度，改父级后整棵子树 level 重算。
 */
@Service
@RequiredArgsConstructor
public class SupplierCategoryService {

    private final SupplierCategoryRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;

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
        return new SupplierCategoryDetail(c.getId(), c.getCode(), c.getName(), c.getLevel(),
                c.getLegacyId(), parentId, parentName, c.getSortOrder(), c.getPath(), childCount);
    }

    @Transactional
    public SupplierCategoryDetail create(SupplierCategorySaveRequest req) {
        tx.bind();
        SupplierCategory c = new SupplierCategory();
        // 编码：留空 → GF 前缀原子取号自动生成；非空 → 查重，冲突 409。
        String code = req.getCode();
        if (code == null || code.isBlank()) {
            code = masterCodeService.nextCode(MasterCodePrefix.SUPPLIER_CATEGORY);
        } else {
            code = code.trim();
            if (repo.existsByCodeAndDeletedFalse(code)) {
                throw new ApiException(ErrorCode.CONFLICT, "编码「" + code + "」已存在，请更换");
            }
        }
        c.setCode(code);
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

    @Transactional
    public SupplierCategoryDetail update(UUID id, SupplierCategoryUpdateRequest req) {
        tx.bind();
        SupplierCategory c = requireCategory(id);
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
        SupplierCategory c = requireCategory(id);
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该分类的子分类");
        }
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    /** 改父级后重算子树 level（findSubtree 按 path 排序，父先于子）。 */
    private void relevelSubtree(UUID rootId) {
        List<SupplierCategory> nodes = repo.findSubtree(rootId);
        Map<UUID, Integer> levelById = new HashMap<>();
        for (SupplierCategory c : nodes) {
            int lvl = c.getParent() == null ? 0 : levelById.getOrDefault(c.getParent().getId(), 0) + 1;
            c.setLevel(lvl);
            levelById.put(c.getId(), lvl);
        }
        repo.saveAll(nodes);
    }

    /** 把扁平分类列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<SupplierCategoryNode> buildTree(List<SupplierCategory> all, UUID rootId) {
        Map<UUID, SupplierCategoryNode> map = new LinkedHashMap<>();
        for (SupplierCategory c : all) {
            map.put(c.getId(), toNode(c));
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

    private SupplierCategoryNode toNode(SupplierCategory c) {
        SupplierCategoryNode n = new SupplierCategoryNode();
        n.setId(c.getId());
        n.setCode(c.getCode());
        n.setName(c.getName());
        n.setLevel(c.getLevel());
        n.setParentId(c.getParent() == null ? null : c.getParent().getId());
        n.setSortOrder(c.getSortOrder());
        n.setLegacyId(c.getLegacyId());
        return n;
    }

    private SupplierCategory requireCategory(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商分类不存在"));
    }
}
