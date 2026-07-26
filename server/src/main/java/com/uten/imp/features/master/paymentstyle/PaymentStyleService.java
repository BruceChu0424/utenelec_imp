package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleDetail;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleNode;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleUpdateRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 收付款类别树 CRUD。范式同 {@code MaterialCategoryService}：
 * 扁平查询 + Java 端 buildTree 组装；create/update 后 em.refresh 读触发器算的 path；
 * 改父级后整棵子树 level 重算。
 *
 * <p>category 不允许通过 update 修改（影响 path 与报表归类），新建时确定。
 */
@Service
@RequiredArgsConstructor
public class PaymentStyleService {

    /** category 白名单（与 V50 CHECK 约束一致）。 */
    public static final Set<String> CATEGORIES = Set.of(
            "ACCOUNT", "LIABILITY", "EQUITY", "EXPENSE", "INCOME", "METHOD");

    private final PaymentStyleRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<PaymentStyleNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderById(), null);
    }

    /** 按大类过滤的子树（前端按 ACCOUNT/EXPENSE/INCOME 分根展示）。 */
    @Transactional(readOnly = true)
    public List<PaymentStyleNode> treeByCategory(String category) {
        if (category != null && !CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.BUSINESS, "未知类别：" + category);
        }
        List<PaymentStyle> all = (category == null)
                ? repo.findByDeletedFalseOrderById()
                : repo.findByCategoryAndDeletedFalseOrderBySortOrderAscNameAsc(category);
        return buildTree(all, null);
    }

    @Transactional(readOnly = true)
    public List<PaymentStyleNode> subtree(UUID rootId) {
        requireStyle(rootId);
        return buildTree(repo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public PaymentStyleDetail detail(UUID id) {
        PaymentStyle s = requireStyle(id);
        UUID parentId = s.getParent() == null ? null : s.getParent().getId();
        String parentName = s.getParent() == null ? null : s.getParent().getName();
        long childCount = repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).size();
        return new PaymentStyleDetail(s.getId(), s.getCode(), s.getName(), s.getCategory(),
                s.getLevel(), s.getLegacyId(), parentId, parentName, s.getSortOrder(), s.getPath(),
                s.isDepartmental(), s.isReceipt(), s.isPayment(), s.getLinkedAccountLegacyId(),
                s.getInitBalance(), s.getStatus(), childCount);
    }

    @Transactional
    public PaymentStyleDetail create(PaymentStyleSaveRequest req) {
        tx.bind();
        if (!CATEGORIES.contains(req.getCategory())) {
            throw new ApiException(ErrorCode.BUSINESS, "未知类别：" + req.getCategory());
        }
        PaymentStyle s = new PaymentStyle();
        s.setCode(req.getCode());
        s.setName(req.getName());
        s.setCategory(req.getCategory());
        s.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        s.setDepartmental(req.isDepartmental());
        s.setReceipt(req.isReceipt());
        s.setPayment(req.isPayment());
        s.setLinkedAccountLegacyId(req.getLinkedAccountLegacyId());
        s.setInitBalance(req.getInitBalance());
        if (req.getStatus() != null && !req.getStatus().isBlank()) s.setStatus(req.getStatus());
        if (req.getParentId() != null) {
            PaymentStyle parent = requireStyle(req.getParentId());
            s.setParent(parent);
            s.setLevel(parent.getLevel() + 1);
        } else {
            s.setLevel(0);
        }
        repo.save(s);
        em.flush();
        em.refresh(s);   // 触发器算 path 后刷新
        return detail(s.getId());
    }

    @Transactional
    public PaymentStyleDetail update(UUID id, PaymentStyleUpdateRequest req) {
        tx.bind();
        PaymentStyle s = requireStyle(id);
        s.setName(req.getName());
        if (req.getSortOrder() != null) s.setSortOrder(req.getSortOrder());
        if (req.getDepartmental() != null) s.setDepartmental(req.getDepartmental());
        if (req.getReceipt() != null) s.setReceipt(req.getReceipt());
        if (req.getPayment() != null) s.setPayment(req.getPayment());
        if (req.getLinkedAccountLegacyId() != null) s.setLinkedAccountLegacyId(req.getLinkedAccountLegacyId());
        if (req.getInitBalance() != null) s.setInitBalance(req.getInitBalance());
        if (req.getStatus() != null && !req.getStatus().isBlank()) s.setStatus(req.getStatus());
        boolean parentChanged = false;
        if (req.getParentId() != null) {
            if (req.getParentId().equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (repo.isDescendant(id, req.getParentId())) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将类别挂到其子分类下（会成环）");
            }
            s.setParent(requireStyle(req.getParentId()));
            parentChanged = true;
        }
        repo.save(s);
        em.flush();
        em.refresh(s);
        if (parentChanged) {
            relevelSubtree(id);
        }
        return detail(id);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        PaymentStyle s = requireStyle(id);
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该类别的子节点");
        }
        s.setDeleted(true);
        s.setDeletedAt(OffsetDateTime.now());
        repo.save(s);
    }

    /** 改父级后重算子树 level（findSubtree 按 path 排序，父先于子）。 */
    private void relevelSubtree(UUID rootId) {
        List<PaymentStyle> nodes = repo.findSubtree(rootId);
        Map<UUID, Integer> levelById = new HashMap<>();
        for (PaymentStyle s : nodes) {
            int lvl = s.getParent() == null ? 0 : levelById.getOrDefault(s.getParent().getId(), 0) + 1;
            s.setLevel(lvl);
            levelById.put(s.getId(), lvl);
        }
        repo.saveAll(nodes);
    }

    /** 把扁平列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<PaymentStyleNode> buildTree(List<PaymentStyle> all, UUID rootId) {
        Map<UUID, PaymentStyleNode> map = new LinkedHashMap<>();
        for (PaymentStyle s : all) {
            map.put(s.getId(), toNode(s));
        }
        List<PaymentStyleNode> roots = new ArrayList<>();
        for (PaymentStyle s : all) {
            PaymentStyleNode node = map.get(s.getId());
            PaymentStyle parent = s.getParent();
            if (parent == null || !map.containsKey(parent.getId())) {
                if (rootId == null || s.getId().equals(rootId)) {
                    roots.add(node);
                }
            } else {
                map.get(parent.getId()).getChildren().add(node);
            }
        }
        return roots;
    }

    private PaymentStyleNode toNode(PaymentStyle s) {
        PaymentStyleNode n = new PaymentStyleNode();
        n.setId(s.getId());
        n.setCode(s.getCode());
        n.setName(s.getName());
        n.setCategory(s.getCategory());
        n.setLevel(s.getLevel());
        n.setParentId(s.getParent() == null ? null : s.getParent().getId());
        n.setSortOrder(s.getSortOrder());
        n.setPath(s.getPath());
        n.setDepartmental(s.isDepartmental());
        n.setReceipt(s.isReceipt());
        n.setPayment(s.isPayment());
        n.setLinkedAccountLegacyId(s.getLinkedAccountLegacyId());
        n.setInitBalance(s.getInitBalance());
        n.setStatus(s.getStatus());
        n.setLegacyId(s.getLegacyId());
        return n;
    }

    private PaymentStyle requireStyle(UUID id) {
        return repo.findById(id)
                .filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "收付款类别不存在"));
    }
}
