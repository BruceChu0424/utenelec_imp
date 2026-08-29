package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
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

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
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

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.PAYMENT_STYLE;
    private static final Set<String> STATUSES = Set.of("使用", "禁用");

    /**
     * 运行时总账、报表或数据库函数按这些物化路径定位系统科目；移动/删除会直接破坏过账链。
     * auto_created 只表示系统补录/迁移占位，不能据此判断为系统关键科目。
     */
    private static final Set<String> PROTECTED_SYSTEM_PATHS = Set.of(
            "/031/", "/032/", "/033/", "/041/", "/042/", "/043/",
            "/101/", "/102/", "/113/", "/123/", "/139/", "/151/",
            "/152/", "/172/", "/173/", "/203/", "/204/", "/205/",
            "/221/", "/301/", "/321/");

    /** 总账服务按 EXPENSE + name 定位的平衡科目；包括迁移前已存在、未标 auto_created 的节点。 */
    private static final Set<String> PROTECTED_EXPENSE_NAMES = Set.of("手续费", "汇兑损益");
    private static final UUID ACCOUNT_BALANCE_CLEARING_STYLE_ID =
            UUID.fromString("40000000-0000-4000-8100-000000000001");

    /** category 白名单（与 CHECK 约束一致）。 */
    public static final Set<String> CATEGORIES = Set.of(
            "ACCOUNT", "LIABILITY", "EQUITY", "EXPENSE", "INCOME", "METHOD");

    private final PaymentStyleRepository repo;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final MasterCodeService masterCodeService;

    @Transactional(readOnly = true)
    public List<PaymentStyleNode> tree() {
        return buildTree(repo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null);
    }

    /** 按大类过滤的子树（前端按 ACCOUNT/EXPENSE/INCOME 分根展示）。 */
    @Transactional(readOnly = true)
    public List<PaymentStyleNode> treeByCategory(String category) {
        if (category != null && !CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.BUSINESS, "未知类别：" + category);
        }
        List<PaymentStyle> all = (category == null)
                ? repo.findByDeletedFalseOrderBySortOrderAscNameAsc()
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
                s.getLevel(), s.getLegacyId(), parentId, parentName, s.getSortOrder(), buildNamePath(s),
                s.isDepartmental(), s.isReceipt(), s.isPayment(), s.getLinkedAccountLegacyId(),
                s.getLinkedAccountId(),
                s.getInitBalance(), s.getStatus(), childCount);
    }

    /** 拼中文 name 路径，向上走 parent 链；用于详情卡显示。
     *  不动 entity.path（物化 code 路径，DB 触发器维护，用于排序/子树查询）。 */
    private String buildNamePath(PaymentStyle s) {
        List<String> names = new ArrayList<>();
        Set<UUID> visited = new HashSet<>();
        PaymentStyle current = s;
        while (current != null && visited.add(current.getId())) {
            if (current.getName() != null && !current.getName().isBlank()) {
                names.add(current.getName());
            }
            current = current.getParent();
        }
        Collections.reverse(names);
        return String.join(" > ", names);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('payment_style:create')")
    @Transactional
    public PaymentStyleDetail create(PaymentStyleSaveRequest req) {
        tx.bind();
        if (!CATEGORIES.contains(req.getCategory())) {
            throw new ApiException(ErrorCode.BUSINESS, "未知类别：" + req.getCategory());
        }
        requireNameDoesNotClaimSystemIdentity(req.getCategory(), null, req.getName());
        if (req.getParentId() != null) {
            lockStyleHierarchy();
        }
        PaymentStyle s = new PaymentStyle();
        s.setCode(masterCodeService.nextCode(CODE_PREFIX));
        s.setName(req.getName());
        s.setCategory(req.getCategory());
        s.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        s.setDepartmental(req.isDepartmental());
        s.setReceipt(req.isReceipt());
        s.setPayment(req.isPayment());
        applyLinkedAccount(s, req.getLinkedAccountId(), req.getLinkedAccountLegacyId());
        s.setInitBalance(req.getInitBalance());
        s.setStatus(normalizeCreateStatus(req.getStatus()));
        if (req.getParentId() != null) {
            PaymentStyle parent = requireStyle(req.getParentId());
            requireSameCategory(req.getCategory(), parent);
            requireParentCanBecomeDirectory(parent);
            s.setParent(parent);
            s.setLevel(parent.getLevel() + 1);
        } else {
            s.setLevel(0);
        }
        s = repo.save(s); // UUID 构造时赋值→isNew=false→save 走 merge 返回托管副本；用返回值，否则 em.refresh(游离 s) 报 "Entity not managed"
        em.flush();
        em.refresh(s);   // 触发器算 path 后刷新
        return detail(s.getId());
    }

    /** 编辑收付款科目：无 @Version 列，整树层级锁串行化每次编辑，防止「仅改备注」覆盖并发的父级/状态/路径变更。系统科目（财务过账固定路径）禁改名/移动/停用；移动须无业务历史引用且不成环。 */
    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('payment_style:edit', 'payment_style:status', 'payment_style:move', 'payment_style:reorder')")
    @Transactional
    public PaymentStyleDetail update(UUID id, PaymentStyleUpdateRequest req) {
        tx.bind();
        boolean moveToRoot = Boolean.TRUE.equals(req.getMoveToRoot());
        if (moveToRoot && req.getParentId() != null) {
            throw new ApiException(ErrorCode.BUSINESS, "parentId 与 moveToRoot 不能同时提交");
        }
        // PaymentStyle has no optimistic version column and Hibernate updates the
        // complete row. Serialize every edit before loading the entity so a
        // metadata-only edit cannot write stale parent/status/path values over a
        // concurrent hierarchy or status change.
        lockStyleHierarchy();
        PaymentStyle s = requireStyle(id);
        String requestedName = req.getName();
        if (requestedName != null && requestedName.isBlank()) {
            throw new ApiException(ErrorCode.BUSINESS, "类别名称不能为空");
        }
        String requestedStatus = normalizeUpdateStatus(req.getStatus());
        UUID currentParentId = s.getParent() == null ? null : s.getParent().getId();
        UUID requestedParentId = moveToRoot ? null : req.getParentId();
        boolean parentChanged = moveToRoot
                ? currentParentId != null
                : requestedParentId != null && !requestedParentId.equals(currentParentId);
        boolean statusChanged = requestedStatus != null
                && !Objects.equals(s.getStatus(), requestedStatus);
        boolean reorderChanged = req.getSortOrder() != null
                && !Objects.equals(s.getSortOrder(), req.getSortOrder());
        boolean editChanged = (requestedName != null && !Objects.equals(s.getName(), requestedName))
                || (req.getDepartmental() != null && s.isDepartmental() != req.getDepartmental())
                || (req.getReceipt() != null && s.isReceipt() != req.getReceipt())
                || (req.getPayment() != null && s.isPayment() != req.getPayment())
                || (req.getLinkedAccountId() != null
                    && !Objects.equals(s.getLinkedAccountId(), req.getLinkedAccountId()))
                || (req.getLinkedAccountLegacyId() != null
                    && !Objects.equals(s.getLinkedAccountLegacyId(), req.getLinkedAccountLegacyId()))
                || (req.getInitBalance() != null
                    && (s.getInitBalance() == null || s.getInitBalance().compareTo(req.getInitBalance()) != 0));
        if (editChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("payment_style:edit");
        }
        if (statusChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("payment_style:status");
        }
        if (parentChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("payment_style:move");
        }
        if (reorderChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("payment_style:reorder");
        }

        if (requestedParentId != null && requestedParentId.equals(currentParentId)) {
            requireSameCategory(s.getCategory(), s.getParent());
        }

        if (requestedName != null
                && isProtectedSystemStyle(s)
                && !Objects.equals(s.getName(), requestedName)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该节点是系统科目，名称被财务流程使用，不能改名");
        }
        requireNameDoesNotClaimSystemIdentity(s.getCategory(), s.getName(), requestedName);
        if (parentChanged && isProtectedSystemStyle(s)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该节点是系统科目，不能移动；其固定路径被财务过账流程使用");
        }

        PaymentStyle requestedParent = null;
        if (parentChanged && requestedParentId != null) {
            if (requestedParentId.equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            requestedParent = requireStyle(requestedParentId);
            requireSameCategory(s.getCategory(), requestedParent);
            if (repo.isDescendant(id, requestedParentId)) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将类别挂到其子分类下(会成环)");
            }
            requireParentCanBecomeDirectory(requestedParent);
        }
        if (parentChanged && repo.hasBusinessReferences(id, true)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该类别或其子类别已有财务历史引用，不能移动；请新建类别承接后续业务，或仅调整使用状态");
        }
        if (isProtectedSystemStyle(s) && "禁用".equals(requestedStatus)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该节点是财务系统科目，必须保持“使用”状态，否则会中断过账或报表");
        }
        if ("使用".equals(requestedStatus)) {
            requireActiveAncestors(parentChanged ? requestedParent : s.getParent());
        }
        if ("禁用".equals(requestedStatus)
                && repo.hasActiveAccountReferences(s.getId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该类别仍被使用中的账户引用，不能停用；请先调整或停用相关账户");
        }
        if ("禁用".equals(requestedStatus)
                && hasActiveDescendant(s.getId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该目录仍有使用中的子类别，不能停用；请先停用或迁移其子类别");
        }
        if (requestedStatus == null
                && parentChanged
                && "使用".equals(s.getStatus())) {
            requireActiveAncestors(requestedParent);
        }

        if (requestedName != null) s.setName(requestedName);
        if (req.getSortOrder() != null) s.setSortOrder(req.getSortOrder());
        if (req.getDepartmental() != null) s.setDepartmental(req.getDepartmental());
        if (req.getReceipt() != null) s.setReceipt(req.getReceipt());
        if (req.getPayment() != null) s.setPayment(req.getPayment());
        if (req.getLinkedAccountId() != null || req.getLinkedAccountLegacyId() != null) {
            applyLinkedAccount(s, req.getLinkedAccountId(), req.getLinkedAccountLegacyId());
        }
        if (req.getInitBalance() != null) s.setInitBalance(req.getInitBalance());
        if (requestedStatus != null) s.setStatus(requestedStatus);
        if (parentChanged) {
            s.setParent(requestedParent);
        }
        repo.save(s);
        em.flush();
        if (parentChanged) {
            rebuildSubtreeHierarchy(id);
        } else {
            em.refresh(s);
        }
        return detail(id);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('payment_style:edit')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        lockStyleHierarchy();
        requireStyle(id);
        throw new ApiException(ErrorCode.CONFLICT,
                "财务类别不能直接删除；请改为“禁用”以保留历史、审计与并发业务引用安全");
    }

    /** 移动后按 parent 关系递归重建整棵子树，不依赖移动前的旧 path 排序。 */
    private void rebuildSubtreeHierarchy(UUID rootId) {
        if (repo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "收付款类别子树结构异常，无法安全移动");
        }
    }

    private void lockStyleHierarchy() {
        PaymentStyleHierarchyLock.lock(em);
    }

    private void requireSameCategory(String category, PaymentStyle parent) {
        if (!Objects.equals(category, parent.getCategory())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "上级类别必须与当前类别同属“" + category + "”大类");
        }
    }

    /**
     * 叶节点一旦有财务引用就已经是可过账科目；给它新增/移入子类别会把它变成
     * 目录节点，使既有政策和后续业务突然不可过账。
     */
    private void requireParentCanBecomeDirectory(PaymentStyle parent) {
        if (!"使用".equals(parent.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "不能在已禁用类别下新增或移动子类别");
        }
        if (!repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(parent.getId()).isEmpty()) {
            return;
        }
        if (isProtectedSystemStyle(parent) || repo.hasBusinessReferences(parent.getId(), false)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "所选上级已被财务业务引用，不能再变为目录；请新建同级目录，或先调整相关业务配置");
        }
    }

    private void requireActiveAncestors(PaymentStyle parent) {
        Set<UUID> visited = new HashSet<>();
        while (parent != null) {
            if (!visited.add(parent.getId())) {
                throw new ApiException(ErrorCode.CONFLICT, "收付款类别层级存在循环，请先修复主档结构");
            }
            if (!"使用".equals(parent.getStatus())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "存在已禁用的上级类别，不能启用当前类别；请先启用其上级");
            }
            parent = parent.getParent();
        }
    }

    private boolean hasActiveDescendant(UUID rootId) {
        return repo.findSubtree(rootId).stream()
                .anyMatch(style -> !style.getId().equals(rootId)
                        && "使用".equals(style.getStatus()));
    }

    private String normalizeCreateStatus(String status) {
        if (status == null || status.isBlank()) {
            return "使用";
        }
        return requireValidStatus(status);
    }

    private String normalizeUpdateStatus(String status) {
        if (status == null) {
            return null;
        }
        return requireValidStatus(status);
    }

    private String requireValidStatus(String status) {
        String normalized = status.trim();
        if (!STATUSES.contains(normalized)) {
            throw new ApiException(ErrorCode.BUSINESS, "状态只能是“使用”或“禁用”");
        }
        return normalized;
    }

    private boolean isProtectedSystemStyle(PaymentStyle style) {
        return PROTECTED_SYSTEM_PATHS.contains(style.getPath())
                || hasProtectedSystemName(style)
                || ACCOUNT_BALANCE_CLEARING_STYLE_ID.equals(style.getId());
    }

    private boolean hasProtectedSystemName(PaymentStyle style) {
        return "EXPENSE".equals(style.getCategory())
                && PROTECTED_EXPENSE_NAMES.contains(style.getName());
    }

    private void requireNameDoesNotClaimSystemIdentity(
            String category, String currentName, String requestedName) {
        boolean currentReserved = currentName != null
                && PROTECTED_EXPENSE_NAMES.contains(currentName);
        boolean requestedReserved = requestedName != null
                && PROTECTED_EXPENSE_NAMES.contains(requestedName);
        if ("EXPENSE".equals(category)
                && !currentReserved
                && requestedReserved) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "“" + requestedName + "”是财务系统保留科目名称，不能用于普通类别");
        }
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
        n.setLinkedAccountId(s.getLinkedAccountId());
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

    /** 正常 API 只按账户 UUID 建立关系；legacy 值只能是与 UUID 一致的兼容影子。 */
    private void applyLinkedAccount(
            PaymentStyle style, UUID linkedAccountId, Integer linkedAccountLegacyId) {
        if (linkedAccountId == null) {
            if (linkedAccountLegacyId != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "linkedAccountLegacyId 不能用于建立关联，请选择账户 UUID");
            }
            return;
        }
        if (!"ACCOUNT".equals(style.getCategory())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "只有账户类科目可以关联账户");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> matches = em.createNativeQuery("""
                        SELECT id, legacy_id
                        FROM accounts
                        WHERE COALESCE(is_deleted,false)=false
                          AND status='使用'
                          AND id=:accountId
                        """)
                .setParameter("accountId", linkedAccountId)
                .getResultList();
        if (matches.size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "关联账户不存在或已禁用");
        }
        Object[] resolved = matches.getFirst();
        Integer canonicalLegacyId = resolved[1] == null
                ? null : ((Number) resolved[1]).intValue();
        if (linkedAccountLegacyId != null
                && !Objects.equals(linkedAccountLegacyId, canonicalLegacyId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "关联账户 UUID 与 legacy 影子不一致");
        }
        style.setLinkedAccountId((UUID) resolved[0]);
        style.setLinkedAccountLegacyId(canonicalLegacyId);
    }
}
