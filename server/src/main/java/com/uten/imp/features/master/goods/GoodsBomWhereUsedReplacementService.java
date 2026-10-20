package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;

/** Replaces current canonical edges only. Frozen demand and historical evidence are never updated. */
@Service
@RequiredArgsConstructor
public class GoodsBomWhereUsedReplacementService {
    public record Request(@NotNull UUID materialGoodsId, @NotNull UUID replacementGoodsId,
                          @NotEmpty @Size(max = 200) List<@NotNull UUID> productIds,
                          boolean confirmUnusualWeight, boolean confirmSecondPeriodicMaterial) {
        public Request(UUID materialGoodsId, UUID replacementGoodsId, List<UUID> productIds) {
            this(materialGoodsId, replacementGoodsId, productIds, false, false);
        }
    }
    public record Commit(@NotNull UUID previewToken) { }
    public record Product(UUID id, String code, String name, boolean selected) { }
    public record Edge(UUID id, UUID parentId, String parentCode, String parentName, BigDecimal qty,
                       String unitName) { }
    public record Preview(UUID previewToken, List<Edge> edges, List<Product> affectedProducts,
                          Instant expiresAt) { }
    public record Result(int replacedEdges, int affectedProducts) { }
    private record Scope(UUID actor, UUID session, UUID impersonator) { }
    private record Plan(List<GoodsBomItem> rows, List<Product> products, String fingerprint) { }
    private record Ticket(Request request, Scope scope, String fingerprint, Instant expiry,
                          AtomicReference<Result> receipt) {
        Ticket(Request request, Scope scope, String fingerprint, Instant expiry) {
            this(request, scope, fingerprint, expiry, new AtomicReference<>());
        }
    }
    private final Map<UUID, Ticket> tickets = new ConcurrentHashMap<>();
    private final GoodsBomService bom;
    private final GoodsBomGraphLock graphLock;
    private final GoodsBomHistoryPermissions historyPermissions;
    private final GoodsRepository goodsRepo;
    private final GoodsBomItemRepository bomRepo;
    private final MasterReferenceValidationPort references;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;
    private final PlatformTransactionManager transactions;

    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('goods:bom:edit')")
    public Preview preview(Request request) {
        Request normalized = normalize(request);
        Scope scope = scope();
        // Validate with the exact authoritative command, then roll back the whole simulation.
        // This also validates periodic quantities, colors, hard gates and duplicate/cycle rules.
        TransactionTemplate simulation = new TransactionTemplate(transactions);
        simulation.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        PreviewState state = simulation.execute(status -> {
            try {
                Plan plan = lockedPlan(normalized);
                List<Edge> edges = plan.rows().stream().map(row -> new Edge(row.getId(),
                        row.getGoods().getId(), row.getGoods().getCode(), row.getGoods().getName(),
                        row.getQty(), row.getComponent().getUnit() == null ? null
                        : row.getComponent().getUnit().getName())).toList();
                apply(normalized, plan);
                em.flush();
                return new PreviewState(plan.fingerprint(), edges, plan.products());
            } finally {
                status.setRollbackOnly();
            }
        });
        Objects.requireNonNull(state);
        tickets.entrySet().removeIf(entry -> entry.getValue().expiry().isBefore(Instant.now()));
        if (tickets.size() >= 2000) throw new ApiException(ErrorCode.VALIDATION_FAILED,
                "替换预览较多，请稍后再试");
        UUID token = UUID.randomUUID();
        Instant expiry = Instant.now().plusSeconds(600);
        tickets.put(token, new Ticket(normalized, scope, state.fingerprint(), expiry));
        return new Preview(token, state.edges(), state.products(), expiry);
    }

    private record PreviewState(String fingerprint, List<Edge> edges, List<Product> products) { }

    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('goods:bom:edit')")
    public Result commit(Commit request) {
        Ticket ticket = tickets.get(request.previewToken());
        if (ticket == null || ticket.expiry().isBefore(Instant.now()) || !ticket.scope().equals(scope()))
            throw changed("替换预览已过期或身份已变化，请重新预览");
        synchronized (ticket) {
            if (ticket.receipt().get() != null) return ticket.receipt().get();
            TransactionTemplate command = new TransactionTemplate(transactions);
            command.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
            Result result = command.execute(status -> {
                Plan plan = lockedPlan(ticket.request());
                if (!ticket.fingerprint().equals(plan.fingerprint()))
                    throw changed("组装信息或货品资料已变化，请重新预览并确认影响范围");
                apply(ticket.request(), plan);
                em.flush();
                historyPermissions.record(Set.of("goods:bom:edit", "production_where_used:view"));
                return new Result(plan.rows().size(), plan.products().size());
            });
            ticket.receipt().set(Objects.requireNonNull(result));
            return result;
        }
    }

    private Plan lockedPlan(Request request) {
        List<UUID> edgeIds = edgeIds(request);
        if (edgeIds.isEmpty()) throw changed("所选产品没有当前有效的该组件关系，历史记录不能替换");
        Set<UUID> parents = new TreeSet<>();
        for (Object[] row : bomRepo.findLiveItemParents(edgeIds)) parents.add(uuid(row[1]));
        goodsRepo.lockBomParents(parents);
        // Same order as learning publication and V739: all parent rows, then the shared graph lock.
        graphLock.acquire();
        Set<UUID> involved = new TreeSet<>(parents);
        involved.add(request.materialGoodsId());
        involved.add(request.replacementGoodsId());
        goodsRepo.lockForReference(involved);
        references.lockGoodsQuantityBasis(involved);
        em.clear();
        references.requireVisibleActiveGoods(request.materialGoodsId());
        references.requireVisibleActiveGoods(request.replacementGoodsId());
        Goods oldComponent = goodsRepo.findById(request.materialGoodsId()).orElseThrow(() -> changed("当前组件不存在"));
        Goods replacement = goodsRepo.findById(request.replacementGoodsId()).orElseThrow(() -> changed("替换组件不存在"));
        requireEquivalentQuantityBasis(oldComponent, replacement);
        List<UUID> refreshed = edgeIds(request);
        if (!new HashSet<>(edgeIds).equals(new HashSet<>(refreshed)))
            throw changed("当前组装关系已变化，请重新预览");
        List<GoodsBomItem> rows = new ArrayList<>(bomRepo.findAllById(edgeIds));
        rows.sort(Comparator.comparing(row -> row.getId().toString()));
        for (UUID parent : parents) references.requireVisibleActiveGoods(parent);
        List<Product> products = affectedProducts(parents, request.productIds());
        for (Product product : products) references.requireVisibleGoods(product.id());
        for (UUID selected : request.productIds()) {
            references.requireVisibleActiveGoods(selected);
            if (products.stream().noneMatch(product -> product.id().equals(selected)))
                throw changed("所选产品中存在仅有历史关系的产品，请取消选择后重试");
        }
        Set<UUID> scopeIds = new TreeSet<>(involved);
        products.forEach(product -> scopeIds.add(product.id()));
        return new Plan(rows, products, fingerprint(scopeIds));
    }

    @SuppressWarnings("unchecked")
    private List<UUID> edgeIds(Request request) {
        List<?> rows = em.createNativeQuery("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM goods WHERE id IN (:products) AND NOT is_deleted AND NOT auto_created
                    UNION
                    SELECT b.component_goods_id FROM goods_bom_items b JOIN descendants p ON p.id=b.goods_id
                    JOIN goods c ON c.id=b.component_goods_id AND NOT c.is_deleted AND NOT c.auto_created
                    WHERE NOT b.is_deleted AND b.qty>0
                )
                SELECT b.id FROM goods_bom_items b JOIN descendants d ON d.id=b.goods_id
                WHERE NOT b.is_deleted AND b.qty>0 AND b.component_goods_id=:material ORDER BY b.id
                """).setParameter("products", request.productIds()).setParameter("material", request.materialGoodsId())
                .getResultList();
        if (rows.size() > 2000) throw new ApiException(ErrorCode.VALIDATION_FAILED,
                "本次替换超过 2000 条组装关系，请分批选择");
        return rows.stream().map(GoodsBomWhereUsedReplacementService::uuid).toList();
    }

    private List<Product> affectedProducts(Set<UUID> parents, List<UUID> selected) {
        List<?> rows = em.createNativeQuery("""
                WITH RECURSIVE affected(id) AS (
                    SELECT id FROM goods WHERE id IN (:parents)
                    UNION
                    SELECT b.goods_id FROM goods_bom_items b JOIN affected a ON a.id=b.component_goods_id
                    JOIN goods p ON p.id=b.goods_id AND NOT p.is_deleted AND NOT p.auto_created
                    WHERE NOT b.is_deleted AND b.qty>0
                ) SELECT g.id,g.code,g.name FROM goods g JOIN affected a ON a.id=g.id ORDER BY g.code,g.id
                """).setParameter("parents", parents).getResultList();
        return rows.stream().map(raw -> {
            Object[] row = (Object[]) raw;
            UUID id = uuid(row[0]);
            return new Product(id, (String) row[1], (String) row[2], selected.contains(id));
        }).toList();
    }

    private void apply(Request request, Plan plan) {
        for (GoodsBomItem row : plan.rows()) {
            BomItemSaveRequest save = new BomItemSaveRequest();
            save.setComponentGoodsId(request.replacementGoodsId());
            save.setQty(row.getQty());
            save.setControlStage(row.getControlStage());
            save.setConsumptionBasis(row.getConsumptionBasis());
            save.setBasisOutputQty(row.getBasisOutputQty());
            save.setAllowPartialPackage(row.isAllowPartialPackage());
            save.setHardGate(row.isHardGate());
            save.setSummary(row.getSummary());
            save.setConfirmUnusualWeight(request.confirmUnusualWeight());
            save.setConfirmSecondPeriodicMaterial(request.confirmSecondPeriodicMaterial());
            // No client price/color/supplier input: the existing authority preserves the row's values.
            bom.update(row.getGoods().getId(), row.getId(), save);
        }
    }

    private String fingerprint(Set<UUID> scopeIds) {
        return String.valueOf(em.createNativeQuery("""
                WITH edges AS (
                    SELECT b.* FROM goods_bom_items b WHERE NOT b.is_deleted
                    AND (b.goods_id IN (:scope) OR b.component_goods_id IN (:scope))
                ), involved AS (
                    SELECT id,version,updated_at,code,name,status,is_deleted,auto_created,owner_employee_id,
                           unit_id,unit_legacy_id,color_id,color_legacy_id,issue_method,periodic_cost_basis,
                           price,source_type,m_weight,m_weight_unit_id,m_weight_unit_legacy_id
                    FROM goods WHERE id IN (:scope) OR id IN (SELECT component_goods_id FROM edges)
                )
                SELECT md5(CAST(jsonb_build_object(
                    'edges',(SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM edges b),
                    'goods',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM involved g),
                    'colors',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM colors c
                        WHERE c.id IN (SELECT color_id FROM involved UNION SELECT color_id FROM edges)
                        OR c.legacy_id IN (SELECT color_legacy_id FROM involved UNION SELECT color_legacy_id FROM edges)),
                    'units',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM units u
                        WHERE u.id IN (SELECT unit_id FROM involved UNION SELECT m_weight_unit_id FROM involved)
                        OR u.legacy_id IN (SELECT unit_legacy_id FROM involved UNION SELECT m_weight_unit_legacy_id FROM involved)),
                    'suppliers',(SELECT jsonb_agg(jsonb_build_object('id',s.id,'updatedAt',s.updated_at,
                        'isDeleted',s.is_deleted,'status',s.status) ORDER BY s.id) FROM suppliers s
                        WHERE s.id IN (SELECT default_supplier_id FROM edges)
                        OR s.legacy_id IN (SELECT vend_legacy_id FROM edges))
                ) AS text))
                """).setParameter("scope", scopeIds).getSingleResult());
    }

    static void requireEquivalentQuantityBasis(Goods oldComponent, Goods replacement) {
        UUID oldUnit = oldComponent.getUnit() == null ? null : oldComponent.getUnit().getId();
        UUID newUnit = replacement.getUnit() == null ? null : replacement.getUnit().getId();
        boolean sameUnit = oldUnit != null && oldUnit.equals(newUnit)
                || oldUnit == null && newUnit == null && oldComponent.getUnitLegacyId() != null
                && oldComponent.getUnitLegacyId().equals(replacement.getUnitLegacyId());
        if (!sameUnit || GoodsPeriodicMaterialRules.isPeriodic(oldComponent)
                != GoodsPeriodicMaterialRules.isPeriodic(replacement))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "两个组件的基本单位或领料方式不同，不能直接沿用用量；请在组装信息中逐项确认后修改");
    }

    private static Request normalize(Request request) {
        if (request.materialGoodsId().equals(request.replacementGoodsId()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "替换组件不能与当前组件相同");
        return new Request(request.materialGoodsId(), request.replacementGoodsId(),
                request.productIds().stream().distinct().sorted().toList(),
                request.confirmUnusualWeight(), request.confirmSecondPeriodicMaterial());
    }

    private Scope scope() {
        CurrentAuthorityGuard.requireAll("production_where_used:view", "goods:bom:edit");
        AuthUser user = currentUser.get().orElseThrow(() -> new IllegalStateException("当前无登录用户"));
        if (user.getImpersonatedBy() != null) throw new ApiException(ErrorCode.FORBIDDEN, "模拟身份只能查看，不能替换组装信息");
        return new Scope(user.getId(), user.getSessionId(), user.getImpersonatedBy());
    }

    private static UUID uuid(Object value) { return value instanceof UUID id ? id : UUID.fromString(String.valueOf(value)); }
    private static ApiException changed(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
