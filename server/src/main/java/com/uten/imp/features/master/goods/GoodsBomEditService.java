package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomEditPreview;
import com.uten.imp.features.master.goods.dto.BomEditRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.BomMoveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The client autosaves an ordered draft; only this explicit commit publishes it.
 * Preview replays the authoritative commands in an independent rollback-only transaction.
 * Those commands only write transactional entities/triggers/outbox. BusinessOutboxReady's
 * sole listener is AFTER_COMMIT, so preview cannot send notices or publish a recipe.
 */
@Service
@PreAuthorize("hasAuthority('goods:bom:edit')")
public class GoodsBomEditService {
    private static final Duration TTL = Duration.ofMinutes(15);
    private static final int MAX_PREVIEWS = 1000;
    private final GoodsBomService bom;
    private final GoodsRepository goodsRepo;
    private final GoodsService goods;
    private final GoodsInlineEditService inlineEdits;
    private final GoodsBomItemRepository rows;
    private final GoodsBomGraphLock graph;
    private final MasterReferenceValidationPort references;
    private final SecurityContextCurrentUser currentUser;
    private final NamedParameterJdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final Validator validator;
    private final TxSessionVars tx;
    private final GoodsBomHistoryPermissions historyPermissions;
    private final TransactionTemplate transactions;
    private final TransactionTemplate snapshotTransactions;
    private final Map<UUID, Pending> previews = new ConcurrentHashMap<>();

    public GoodsBomEditService(GoodsBomService bom, GoodsRepository goodsRepo, GoodsBomItemRepository rows,
                               GoodsBomGraphLock graph, MasterReferenceValidationPort references,
                               SecurityContextCurrentUser currentUser, NamedParameterJdbcTemplate db,
                               EntityManager em, ObjectMapper json, Validator validator,
                               PlatformTransactionManager transactionManager, TxSessionVars tx,
                               GoodsBomHistoryPermissions historyPermissions, GoodsService goods, GoodsInlineEditService inlineEdits) {
        this.bom = bom;
        this.goodsRepo = goodsRepo;
        this.goods = goods;
        this.inlineEdits = inlineEdits;
        this.rows = rows;
        this.graph = graph;
        this.references = references;
        this.currentUser = currentUser;
        this.db = db;
        this.em = em;
        this.json = json;
        this.validator = validator;
        this.tx = tx;
        this.historyPermissions = historyPermissions;
        this.transactions = new TransactionTemplate(transactionManager);
        this.transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.snapshotTransactions = new TransactionTemplate(transactionManager);
        this.snapshotTransactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.snapshotTransactions.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        this.snapshotTransactions.setReadOnly(true);
    }

    public record GoodsSnapshot(UUID id, long version, String model, String spec, String material,
                                String sourceType, boolean componentGoodsWritable) { }
    public record SnapshotView(List<BomItemView> items, String fingerprint, GoodsSnapshot goods) { }
    private static final Set<String> GOODS_FIELDS = Set.of("model", "spec", "material", "sourceType");
    public record CommitResult(int operationCount, List<UUID> affectedGoodsIds, Map<UUID, UUID> itemIds) { }
    private record Identity(UUID user, UUID session, UUID impersonator) { }
    private static final class Pending {
        final UUID root;
        final Identity identity;
        final String requestHash;
        final String stateHash;
        final BomEditPreview preview;
        CommitResult result;

        Pending(UUID root, Identity identity, String requestHash, String stateHash, BomEditPreview preview) {
            this.root = root;
            this.identity = identity;
            this.requestHash = requestHash;
            this.stateHash = stateHash;
            this.preview = preview;
        }
    }

    public SnapshotView snapshot(UUID parent) {
        identity();
        return snapshotTransactions.execute(status -> {
            // List and digest must describe the same MVCC snapshot, including component master fields.
            references.requireVisibleGoods(parent);
            Goods goods = goodsRepo.findById(parent).orElseThrow(() -> conflict("货品不存在"));
            if (goods.isDeleted() || goods.isAutoCreated()
                    || goods.getStatus() != null && !"使用".equals(goods.getStatus())) {
                throw conflict("货品已删除、停用或仅为迁移占位，不能进入编辑模式");
            }
            return new SnapshotView(bom.list(parent), fingerprint(parent), goodsSnapshot(goods));
        });
    }

    private GoodsSnapshot goodsSnapshot(Goods item) {
        AuthUser user = currentUser.get().orElseThrow(() ->
                new ApiException(ErrorCode.FORBIDDEN, "当前登录状态无效"));
        if (!hasPermission(user, "goods:view")) return null;
        goods.requireVisible(item);
        boolean writable = hasPermission(user, "goods:edit") && user.getEmployeeId() != null
                && !user.isVisitor() && user.isAccountNonLocked() && !user.isMustChangePassword()
                && user.getImpersonatedBy() == null && goods.canWrite(item);
        return new GoodsSnapshot(item.getId(), item.getVersion(), item.getModel(), item.getSpec(),
                item.getMaterial(), item.getSourceType(), writable);
    }

    private static boolean hasPermission(AuthUser user, String permission) {
        return user.isSuperAdmin() || !user.isMustChangePassword() && user.getPermissions().contains(permission);
    }

    public BomEditPreview preview(UUID root, BomEditRequest request) {
        Identity actor = identity();
        validate(request);
        prune();
        UUID token = UUID.randomUUID();
        String requestHash = requestHash(request);
        Pending pending = transactions.execute(status -> {
            // Force rollback even when a domain guard throws after one of the earlier commands.
            try {
                Set<UUID> covered = prepare(root, request);
                String state = stateHash(request);
                Replay replay = replay(root, request, covered);
                em.flush(); // Exercise database ownership, color, lineage and cycle guards too.
                List<BomEditPreview.AffectedParent> affected = impacts(root, replay.affected);
                int others = otherUsageCount(root, replay.affected);
                BomEditPreview result = new BomEditPreview(token.toString(), request.operations().size(),
                        affected, others, Instant.now().plus(TTL), replay.warnings());
                return new Pending(root, actor, requestHash, state, result);
            } finally {
                status.setRollbackOnly();
            }
        });
        previews.put(token, Objects.requireNonNull(pending));
        return pending.preview;
    }

    public CommitResult commit(UUID root, BomEditRequest request) {
        Identity actor = identity();
        validate(request);
        UUID token;
        try { token = UUID.fromString(request.previewToken()); }
        catch (RuntimeException error) { throw conflict("请先预览本次组装修改，再确认保存"); }
        Pending pending = previews.get(token);
        if (pending == null || !pending.root.equals(root) || !pending.identity.equals(actor)
                || !pending.requestHash.equals(requestHash(request))) {
            throw conflict("预览不属于当前账号、会话或修改内容，请重新预览");
        }
        synchronized (pending) {
            if (!pending.preview.expiresAt().isAfter(Instant.now())) {
                previews.remove(token, pending);
                throw conflict("本次预览已过期，请重新预览后保存");
            }
            // A lost successful response can be retried without writing a second time.
            if (pending.result != null) return pending.result;
            if (!Boolean.TRUE.equals(request.confirmSharedChanges())) {
                throw conflict("请确认将本次修改同步到这些组件自身及所有引用位置");
            }
            CommitResult result = transactions.execute(status -> {
                Set<UUID> covered = prepare(root, request);
                if (!pending.stateHash.equals(stateHash(request))) {
                    throw conflict("组装结构、引用范围或相关资料已变化，请重新预览；本次未保存");
                }
                Replay replay = replay(root, request, covered);
                em.flush();
                if (!pending.preview.affectedParents().equals(impacts(root, replay.affected))
                        || pending.preview.otherUsageCount() != otherUsageCount(root, replay.affected)
                        || !pending.preview.warnings().equals(replay.warnings())) {
                    throw conflict("同步影响范围已变化，请重新预览；本次未保存");
                }
                Set<String> required = new LinkedHashSet<>(Set.of("goods:bom:edit"));
                for (var operation : request.operations()) {
                    if (operation.type() == BomEditRequest.Type.CREATE) required.add("goods:bom:create");
                    if (operation.type() == BomEditRequest.Type.DELETE) required.add("goods:bom:delete");
                    if (operation.type() == BomEditRequest.Type.UPDATE_GOODS) required.add("goods:edit");
                }
                historyPermissions.record(required);
                return new CommitResult(request.operations().size(), List.copyOf(replay.affected),
                        Map.copyOf(replay.ids));
            });
            pending.result = Objects.requireNonNull(result);
            return result;
        }
    }

    private Identity identity() {
        CurrentAuthorityGuard.requireAll("goods:bom:edit");
        AuthUser user = currentUser.get().orElseThrow(() ->
                new ApiException(ErrorCode.FORBIDDEN, "当前登录状态无效"));
        if (user.getImpersonatedBy() != null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "模拟身份为只读状态，不能保存组装信息");
        }
        return new Identity(user.getId(), user.getSessionId(), user.getImpersonatedBy());
    }

    private void validate(BomEditRequest request) {
        if (request == null || !validator.validate(request).isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "组装草稿缺少有效操作、快照或必填字段");
        }
        int count = 0;
        Set<UUID> editedGoods = new HashSet<>();
        for (var operation : request.operations()) {
            if (operation.type() == BomEditRequest.Type.UPDATE_GOODS) {
                if (operation.goodsId() == null || operation.goodsVersion() == null
                        || operation.goodsVersion() < 0 || operation.goodsChanges() == null
                        || operation.goodsChanges().isEmpty()
                        || operation.goodsChanges().keySet().stream()
                        .anyMatch(key -> key == null || !GOODS_FIELDS.contains(key))
                        || operation.body() != null || operation.itemId() != null || operation.clientItemId() != null
                        || operation.itemIds() != null || operation.moves() != null
                        || !editedGoods.add(operation.goodsId())) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,
                            "货品资料修改须保留原始版本，每个货品合并一次，且只能修改型号、规格、材质和来源");
                }
                for (var change : operation.goodsChanges().entrySet()) {
                    JsonNode value = change.getValue();
                    if (value == null || !value.isNull() && !value.isTextual()
                            || value.isTextual() && value.textValue().length() > 1000
                            || "sourceType".equals(change.getKey()) && !value.isNull()
                            && !Set.of("自制", "采购", "委外").contains(value.textValue())) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "货品资料字段格式不正确，请核对型号、规格、材质和来源");
                    }
                }
            } else if (operation.goodsVersion() != null || operation.goodsChanges() != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "组装关系操作不能夹带货品主档修改");
            }
            count += Math.max(1, Math.max(operation.itemIds() == null ? 0 : operation.itemIds().size(),
                    operation.moves() == null ? 0 : operation.moves().size()));
        }
        if (count > 500) throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多保存 500 项组装操作");
    }

    private Set<UUID> prepare(UUID root, BomEditRequest request) {
        Set<UUID> covered = new LinkedHashSet<>();
        for (var snapshot : request.snapshots()) {
            if (!covered.add(snapshot.goodsId())) throw conflict("同一父件不能提交多个原始快照");
        }
        if (!covered.contains(root)) throw conflict("缺少当前货品的原始组装快照");
        // V739 learning/manual commands take parent rows before the shared graph lock.
        Set<UUID> lockedGoods = new LinkedHashSet<>(covered);
        for (Object[] edge : rows.findOperationalEdges(covered)) lockedGoods.add((UUID) edge[2]);
        for (var operation : request.operations()) {
            if (operation.body() != null && operation.body().getComponentGoodsId() != null) {
                lockedGoods.add(operation.body().getComponentGoodsId());
            }
        }
        goodsRepo.lockBomParents(lockedGoods);
        graph.acquire();
        em.clear(); // Discard any entity loaded before waiting on the locks.
        for (var snapshot : request.snapshots()) {
            references.requireVisibleActiveGoods(snapshot.goodsId());
            if (!snapshot.fingerprint().equals(fingerprint(snapshot.goodsId()))) {
                throw conflict("组装信息或相关货品资料已被修改，请刷新后重新编辑；本次未保存");
            }
        }
        for (var operation : request.operations()) {
            if (operation.type() != BomEditRequest.Type.UPDATE_GOODS) continue;
            CurrentAuthorityGuard.requireAll("goods:view", "goods:edit");
            Goods target = goodsRepo.findById(operation.goodsId()).filter(item -> !item.isDeleted())
                    .orElseThrow(() -> conflict("货品不存在"));
            goods.requireVisible(target);
            goods.requireWritable(target);
            if (target.getVersion() != operation.goodsVersion()) {
                throw conflict("货品已有后续修改，请刷新后重新编辑；未覆盖任何修改");
            }
        }
        return covered;
    }

    private static final class Replay {
        final Set<UUID> affected = new LinkedHashSet<>();
        final Map<UUID, UUID> ids = new LinkedHashMap<>();
        final Map<UUID, List<String>> warningsByItem = new LinkedHashMap<>();
        UUID resolve(UUID id) { return ids.getOrDefault(id, id); }
        void rememberWarnings(BomItemView row) {
            warningsByItem.remove(row.getId());
            if (row.getWarnings() != null && !row.getWarnings().isEmpty()) {
                warningsByItem.put(row.getId(), List.copyOf(row.getWarnings()));
            }
        }
        List<String> warnings() {
            return warningsByItem.values().stream().flatMap(List::stream).distinct().toList();
        }
    }

    private Replay replay(UUID root, BomEditRequest request, Set<UUID> covered) {
        Replay replay = new Replay();
        for (var operation : request.operations()) {
            UUID parent = operation.goodsId() == null ? root : operation.goodsId();
            switch (operation.type()) {
                case UPDATE_GOODS -> {
                    CurrentAuthorityGuard.requireAll("goods:view", "goods:edit");
                    requireParent(root, parent, covered);
                    // prepare already proved the caller's original master version under
                    // the same row lock. Earlier recipe operations can advance this
                    // parent's version through their own material-cost recalculation.
                    em.flush();
                    long version = goodsRepo.findById(parent).orElseThrow(() -> conflict("货品不存在")).getVersion();
                    inlineEdits.patch(parent, Map.of("version", json.valueToTree(version)), operation.goodsChanges());
                    // A master change is visible on every recipe referencing this component.
                    replay.affected.add(parent);
                    em.flush();
                }
                case CREATE -> {
                    CurrentAuthorityGuard.requireAll("goods:bom:create");
                    requireParent(root, parent, covered);
                    requireBody(operation);
                    UUID clientId = operation.clientItemId();
                    if (clientId == null || replay.ids.containsKey(clientId) || rows.existsById(clientId)) {
                        throw conflict("新增组件的草稿行标识缺失或重复");
                    }
                    BomItemView saved = bom.create(parent, operation.body());
                    replay.rememberWarnings(saved);
                    replay.ids.put(clientId, saved.getId());
                    replay.affected.add(parent);
                }
                case UPDATE -> {
                    requireParent(root, parent, covered);
                    requireBody(operation);
                    UUID id = replay.resolve(operation.itemId());
                    GoodsBomItem row = requireRow(id);
                    if (!row.getGoods().getId().equals(parent)) throw conflict("组装行所属父件已变化");
                    replay.rememberWarnings(bom.update(parent, id, operation.body()));
                    replay.affected.add(parent);
                }
                case DELETE -> {
                    CurrentAuthorityGuard.requireAll("goods:bom:delete");
                    List<UUID> requested = operation.itemIds() != null ? operation.itemIds()
                            : operation.itemId() == null ? List.of() : List.of(operation.itemId());
                    if (requested.isEmpty()) throw conflict("请选择要删除的组件行");
                    List<UUID> ids = requested.stream().map(replay::resolve).distinct().toList();
                    for (UUID id : ids) {
                        UUID actualParent = requireRow(id).getGoods().getId();
                        requireParent(root, actualParent, covered);
                        replay.affected.add(actualParent);
                    }
                    bom.deleteAll(root, ids);
                    ids.forEach(replay.warningsByItem::remove);
                    em.flush();
                    em.clear(); // Native batch delete must not leave live cached entities behind.
                }
                case MOVE -> {
                    if (operation.moves() == null || operation.moves().isEmpty()) throw conflict("缺少移动的组件行");
                    for (var requested : operation.moves()) {
                        UUID id = replay.resolve(requested.getItemId());
                        GoodsBomItem row = requireRow(id);
                        UUID oldParent = row.getGoods().getId();
                        UUID target = requested.getTargetParentGoodsId();
                        UUID component = row.getComponent().getId();
                        requireParent(root, oldParent, covered);
                        requireParent(root, target, covered);
                        BomMoveRequest.Move move = new BomMoveRequest.Move();
                        move.setItemId(id);
                        move.setTargetParentGoodsId(target);
                        move.setAnchorItemId(replay.resolve(requested.getAnchorItemId()));
                        move.setAfterAnchor(requested.isAfterAnchor());
                        bom.moveAll(root, List.of(move));
                        em.flush();
                        if (!oldParent.equals(target)) {
                            replay.warningsByItem.remove(id);
                            UUID freshId = rows.findByGoods_IdAndComponent_IdAndDeletedFalse(target, component)
                                    .orElseThrow(() -> conflict("移动后的组件行不存在")).getId();
                            replay.ids.replaceAll((key, value) -> value.equals(id) ? freshId : value);
                            replay.ids.put(id, freshId);
                        }
                        replay.affected.add(oldParent);
                        replay.affected.add(target);
                    }
                }
            }
        }
        return replay;
    }

    private void requireBody(BomEditRequest.Operation operation) {
        if (operation.body() == null || !validator.validate(operation.body()).isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "新增或编辑组件必须提供有效组件资料");
        }
    }

    private GoodsBomItem requireRow(UUID id) {
        if (id == null) throw conflict("缺少组装行标识");
        return rows.findById(id).filter(row -> !row.isDeleted())
                .orElseThrow(() -> conflict("组件行已不存在，请刷新后重新编辑"));
    }

    private void requireParent(UUID root, UUID parent, Set<UUID> covered) {
        if (!covered.contains(parent)) throw conflict("缺少被修改父件的原始快照，请重新加载组装信息");
        references.requireVisibleActiveGoods(parent);
        if (root.equals(parent)) return;
        Set<UUID> visited = new HashSet<>(Set.of(root));
        Set<UUID> frontier = Set.of(root);
        for (int depth = 0; depth < GoodsBomService.MAX_DEPTH && !frontier.isEmpty(); depth++) {
            Set<UUID> next = new HashSet<>();
            for (Object[] edge : rows.findOperationalEdges(frontier)) {
                UUID component = (UUID) edge[2];
                if (component.equals(parent)) return;
                if (visited.add(component)) next.add(component);
            }
            frontier = next;
        }
        throw new ApiException(ErrorCode.FORBIDDEN, "只能修改当前货品组装树内的组件资料");
    }

    private String fingerprint(UUID parent) {
        String state = db.queryForObject("""
                WITH edges AS (SELECT * FROM goods_bom_items WHERE goods_id=:id AND NOT is_deleted),
                involved AS (
                    SELECT id,version,updated_at,code,name,status,is_deleted,auto_created,owner_employee_id,
                           unit_id,unit_legacy_id,color_id,color_legacy_id,issue_method,periodic_cost_basis,
                           model,spec,material,price,source_type,m_weight,m_weight_unit_id,m_weight_unit_legacy_id
                    FROM goods WHERE id=:id OR id IN (SELECT component_goods_id FROM edges))
                SELECT jsonb_build_object(
                    'goods',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM involved g),
                    'edges',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM edges e),
                    'usage',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.bom_item_id)
                        FROM v_goods_bom_item_usage u WHERE u.bom_item_id IN(SELECT id FROM edges)),
                    'colors',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM colors c
                        WHERE c.id IN(SELECT color_id FROM involved UNION SELECT color_id FROM edges)
                           OR c.legacy_id IN(SELECT color_legacy_id FROM involved UNION SELECT color_legacy_id FROM edges)),
                    'units',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM units u
                        WHERE u.id IN(SELECT unit_id FROM involved UNION SELECT m_weight_unit_id FROM involved)
                           OR u.legacy_id IN(SELECT unit_legacy_id FROM involved UNION SELECT m_weight_unit_legacy_id FROM involved)),
                    'suppliers',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM suppliers s
                        WHERE s.id IN(SELECT default_supplier_id FROM edges)
                           OR s.legacy_id IN(SELECT vend_legacy_id FROM edges))
                )::text
                """, Map.of("id", parent), String.class);
        // Snapshots include private prices; a public digest must not support offline price guesses.
        return tx.hmac("goods-bom-edit-snapshot:v1\n" + state);
    }

    private String stateHash(BomEditRequest request) {
        // Bind the confirmation to every current reference path, including references not visible to this user.
        // Only the digest leaves this method; names of unauthorized references are never returned.
        String topology = db.queryForObject("""
                SELECT md5(COALESCE(string_agg(b.id::text||':'||b.goods_id::text||':'||b.component_goods_id::text,
                    ',' ORDER BY b.id),''))
                FROM goods_bom_items b JOIN goods p ON p.id=b.goods_id JOIN goods c ON c.id=b.component_goods_id
                WHERE NOT b.is_deleted AND NOT p.is_deleted AND NOT c.is_deleted
                    AND NOT p.auto_created AND NOT c.auto_created
                """, Map.of(), String.class);
        List<String> states = new ArrayList<>();
        for (var snapshot : request.snapshots()) states.add(fingerprint(snapshot.goodsId()));
        return sha256(topology + states);
    }

    private List<BomEditPreview.AffectedParent> impacts(UUID root, Set<UUID> parents) {
        Map<UUID, Goods> goods = new LinkedHashMap<>();
        for (Goods item : goodsRepo.findAllById(parents)) goods.put(item.getId(), item);
        List<BomEditPreview.AffectedParent> result = new ArrayList<>();
        for (UUID id : parents) {
            Goods item = goods.get(id);
            if (item == null) throw conflict("被修改货品已不存在");
            result.add(new BomEditPreview.AffectedParent(id, item.getCode(), item.getName(),
                    otherUsageCount(root, Set.of(id))));
        }
        return List.copyOf(result);
    }

    private int otherUsageCount(UUID root, Set<UUID> parents) {
        if (parents.isEmpty()) return 0;
        Integer count = db.queryForObject("""
                WITH RECURSIVE ancestors(id) AS (
                    SELECT b.goods_id FROM goods_bom_items b JOIN goods p ON p.id=b.goods_id
                    WHERE b.component_goods_id IN(:parents) AND NOT b.is_deleted
                        AND NOT p.is_deleted AND NOT p.auto_created
                    UNION
                    SELECT b.goods_id FROM ancestors a JOIN goods_bom_items b ON b.component_goods_id=a.id
                        JOIN goods p ON p.id=b.goods_id
                    WHERE NOT b.is_deleted AND NOT p.is_deleted AND NOT p.auto_created
                ) SELECT count(*) FROM ancestors WHERE id<>:root AND id NOT IN(:parents)
                """, Map.of("parents", parents, "root", root), Integer.class);
        return count == null ? 0 : count;
    }

    private String requestHash(BomEditRequest request) {
        List<Object> payload = new ArrayList<>();
        payload.add(request.operations());
        payload.add(request.snapshots());
        // An omitted reference and an explicit null have different update semantics.
        payload.add(request.operations().stream().map(op -> op.body() == null ? List.of()
                : List.of(op.body().hasColorReference(), op.body().hasDefaultSupplierReference())).toList());
        try { return sha256(json.writeValueAsString(payload)); }
        catch (JsonProcessingException error) { throw new IllegalArgumentException("无法读取组装草稿", error); }
    }

    private static String sha256(String value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(String.valueOf(value).getBytes(StandardCharsets.UTF_8))); }
        catch (NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
    }

    private void prune() {
        Instant now = Instant.now();
        previews.entrySet().removeIf(entry -> !entry.getValue().preview.expiresAt().isAfter(now));
        if (previews.size() >= MAX_PREVIEWS) {
            throw conflict("当前待确认的组装预览过多，请稍后重试");
        }
    }

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
