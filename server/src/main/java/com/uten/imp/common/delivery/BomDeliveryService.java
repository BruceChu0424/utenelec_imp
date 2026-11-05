package com.uten.imp.common.delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.BomGraphLockPort;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import static com.uten.imp.common.delivery.DeliveryBom.*;

/**
 * Authoritative, visibility-scoped delivery configuration; never accepts a client recipe or stock quantity.
 * The complete recipe includes PERIODIC goods: an explicitly split customer delivery can ship one
 * as an actual frontier component. DeliveryFrontier selects that boundary; ordinary manufacturing
 * consumption still excludes periodic edges in the production reader.
 */
@Service
@RequiredArgsConstructor
public class BomDeliveryService {
    private final EntityManager em;
    private final MasterReferenceValidationPort references;
    private final BomGraphLockPort graphLock;
    private final ObjectMapper mapper;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.security.TxSessionVars tx;
    private static final int MAX_NODES = 10000;
    private static final int MAX_DEPTH = 64;

    /** Cheap default-order probe, under the same graph transaction lock as full snapshots. */
    @Transactional(readOnly = true)
    public boolean hasRequiredOperations(UUID goodsId) {
        return probeRequiredOperations(goodsId,true);
    }
    @Transactional
    public boolean hasRequiredOperationsAdmitted(AdmittedSource source) {
        references.resolveAdmittedSourceGoodsUnit(source.goodsId(),source.unitId(),source.unitRate(),1);
        return probeRequiredOperations(source.goodsId(),false);
    }
    private boolean probeRequiredOperations(UUID goodsId,boolean requireVisibility) {
        if(goodsId==null)return false;
        if (requireVisibility) {
            references.requireVisibleGoods(goodsId);
        }
        graphLock.acquire();
        return Boolean.TRUE.equals(em.createNativeQuery("""
            WITH RECURSIVE reachable(id) AS (SELECT CAST(:id AS uuid) UNION
                SELECT b.component_goods_id FROM goods_bom_items b JOIN reachable r ON r.id=b.goods_id WHERE NOT b.is_deleted)
            SELECT EXISTS(SELECT 1 FROM reachable r JOIN goods_bom_items b ON b.goods_id=r.id AND NOT b.is_deleted
                JOIN goods_bom_delivery_rules rule ON rule.bom_edge_id=b.id WHERE jsonb_array_length(rule.required_operations)>0)
            """).setParameter("id",goodsId).getSingleResult());
    }

    @Transactional(readOnly = true)
    public Snapshot snapshot(UUID goodsId) {
        return readSnapshot(goodsId,true);
    }
    private Snapshot readSnapshot(UUID goodsId,boolean requireVisibility) {
        if(requireVisibility) references.requireVisibleGoods(goodsId);
        graphLock.acquire();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
            WITH RECURSIVE reachable(id) AS (
                SELECT CAST(:id AS uuid)
                UNION
                SELECT b.component_goods_id FROM goods_bom_items b
                JOIN reachable r ON r.id=b.goods_id WHERE NOT b.is_deleted
            )
            SELECT b.id,b.goods_id,b.component_goods_id,b.qty,b.consumption_basis,b.basis_output_qty,
                b.allow_partial_package,COALESCE(b.color_id,c.color_id),color.name,
                c.code,c.name,c.spec,c.unit_id,u.name,c.source_type,c.is_deleted,c.auto_created,
                COALESCE(rule.mandatory_assembly,false),COALESCE(rule.material_role,'UNCLASSIFIED'),
                COALESCE(CAST(rule.required_operations AS text),'[]'),b.sort_order,
                c.version,
                NULLIF(concat_ws(',',
                  %s,
                  CASE WHEN c.auto_created THEN 'GOODS_PLACEHOLDER' WHEN c.status='禁用' THEN 'GOODS_DISABLED' END),'')
            FROM reachable r JOIN goods_bom_items b ON b.goods_id=r.id AND NOT b.is_deleted
            JOIN goods c ON c.id=b.component_goods_id
            LEFT JOIN units u ON u.id=c.unit_id AND NOT u.is_deleted
            LEFT JOIN colors color ON color.id=COALESCE(b.color_id,c.color_id) AND NOT color.is_deleted
            LEFT JOIN goods_bom_delivery_rules rule ON rule.bom_edge_id=b.id
            ORDER BY b.goods_id,b.sort_order,b.id
            """.formatted(BomReferenceIdentitySql.edgeProblems("b","c","u","color")))
                .setParameter("id", goodsId).setMaxResults(MAX_NODES + 1).getResultList();
        if (rows.size() > MAX_NODES) throw invalid("BOM超过本次允许的10000条边，请拆分后处理");
        Object[] rootRow = (Object[]) em.createNativeQuery("""
            SELECT g.id,g.code,g.name,g.spec,g.unit_id,u.name,g.color_id,c.name,g.source_type,
                g.is_deleted,g.auto_created,g.version,
                NULLIF(concat_ws(',',
                  CASE WHEN g.unit_id IS NULL THEN 'UNIT_MISSING' WHEN u.id IS NULL OR u.is_deleted THEN 'UNIT_DELETED' END,
                  CASE WHEN g.color_id IS NOT NULL AND (c.id IS NULL OR c.is_deleted) THEN 'COLOR_DELETED' END,
                  CASE WHEN g.color_id IS NULL AND NULLIF(g.color_legacy_id,0) IS NOT NULL THEN 'COMPONENT_COLOR_LEGACY' END,
                  CASE WHEN g.is_deleted THEN 'GOODS_DELETED' WHEN g.auto_created THEN 'GOODS_PLACEHOLDER' WHEN g.status='禁用' THEN 'GOODS_DISABLED' END),'')
                FROM goods g
            LEFT JOIN units u ON u.id=g.unit_id LEFT JOIN colors c ON c.id=g.color_id WHERE g.id=:id
            """).setParameter("id", goodsId).getSingleResult();
        LinkedHashSet<UUID> visible = new LinkedHashSet<>(); visible.add(goodsId);
        for (Object[] row : rows) visible.add(uuid(row[2]));
        if(requireVisibility) references.requireVisibleGoodsBatch(visible);
        Map<UUID,List<Object[]>> byParent = new HashMap<>();
        rows.forEach(row -> byParent.computeIfAbsent(uuid(row[1]), ignored -> new ArrayList<>()).add(row));
        int[] count = {0};
        List<Node> children = children(goodsId, List.of(), byParent, new HashSet<>(Set.of(goodsId)), count);
        Node root = new Node(List.of(), null, goodsId, string(rootRow[1]), string(rootRow[2]),
                uuid(rootRow[4]), string(rootRow[5]), uuid(rootRow[6]), string(rootRow[7]), string(rootRow[3]),
                string(rootRow[8]), "1", "PER_UNIT", "1", true,
                Boolean.TRUE.equals(rootRow[9]) || Boolean.TRUE.equals(rootRow[10]) ? ChildrenState.MISSING
                        : children.isEmpty() ? ChildrenState.NONE : ChildrenState.LOADED,
                false, MaterialRole.PART, List.of(), children,rootRow.length>12?identityIssues(rootRow[12]):List.of());
        // A commercial/master label or price update is not a recipe change. Hash only delivery authority.
        String fingerprint = fingerprint(recipeIdentity(root));
        return new Snapshot(1, goodsId, fingerprint, root);
    }

    private List<Node> children(UUID parent, List<UUID> path, Map<UUID,List<Object[]>> byParent,
            Set<UUID> ancestors, int[] count) {
        List<Node> out = new ArrayList<>();
        for (Object[] row : byParent.getOrDefault(parent, List.of())) {
            if (++count[0] > MAX_NODES) throw invalid("BOM路径展开超过10000个节点，请拆分后处理");
            UUID edge = uuid(row[0]), goods = uuid(row[2]);
            List<UUID> next = new ArrayList<>(path); next.add(edge);
            boolean missing = ancestors.contains(goods) || next.size() >= MAX_DEPTH
                    || Boolean.TRUE.equals(row[15]) || Boolean.TRUE.equals(row[16]);
            List<Node> nested = List.of();
            if (!missing) {
                ancestors.add(goods); nested = children(goods, next, byParent, ancestors, count); ancestors.remove(goods);
            }
            out.add(new Node(next, edge, goods, string(row[9]), string(row[10]), uuid(row[12]), string(row[13]),
                    uuid(row[7]), string(row[8]), string(row[11]), string(row[14]), decimal(row[3]), string(row[4]),
                    decimal(row[5]), !Boolean.FALSE.equals(row[6]), missing ? ChildrenState.MISSING
                            : nested.isEmpty() ? ChildrenState.NONE : ChildrenState.LOADED,
                    Boolean.TRUE.equals(row[17]), MaterialRole.valueOf(string(row[18])), operations(string(row[19])), nested,
                    row.length>22?identityIssues(row[22]):List.of()));
        }
        return List.copyOf(out);
    }

    @Transactional
    public Preview resolve(UUID goodsId, UUID unitId, BigDecimal unitRate, BigDecimal qty, DeliveryPlan plan) {
        if(qty==null || qty.signum()<=0 || qty.precision()-qty.scale()>14 || qty.scale()>4)
            throw invalid("交付数量须为正数，最多14位整数和4位小数");
        var unit = references.resolveVisibleActiveGoodsUnit(goodsId, unitId, unitRate, 1);
        Snapshot snapshot = snapshot(goodsId);
        if (plan != null && plan.bomFingerprint() != null && !plan.bomFingerprint().equals(snapshot.bomFingerprint()))
            throw new ApiException(ErrorCode.CONFLICT, "产品BOM或交付约束已变化，请重新打开交付配置核对后确认");
        BigDecimal baseQty = qty.multiply(unit.unitRate());
        return DeliveryFrontier.resolve(snapshot, baseQty, plan);
    }

    /** Save/approval boundary requires a reviewed fingerprint for every configured BOM. */
    @Transactional
    public Preview requireResolved(UUID goodsId, UUID unitId, BigDecimal unitRate, BigDecimal qty,
            DeliveryPlan plan, boolean requireConfirmedPackaging) {
        if (plan != null && plan.requiresPhysicalFulfillment() && (plan.bomFingerprint() == null || plan.bomFingerprint().isBlank()))
            throw new ApiException(ErrorCode.CONFLICT, "请先预览并确认本单交付BOM后保存");
        Preview result = resolve(goodsId, unitId, unitRate, qty, plan);
        if (!result.issues().isEmpty()) throw invalid(result.issues().getFirst().message());
        if (requireConfirmedPackaging && result.deliveryPlan().packaging() == DeliveryPlan.Packaging.PENDING)
            throw invalid("包装安排待确认，不能审核或生成生产需求");
        for (Item item : result.items()) references.requireVisibleActiveGoods(item.goodsId());
        return result;
    }

    /** The source document's owning service performs object-scope/claim/lock admission before calling. */
    @Transactional
    public Preview requireResolvedAdmitted(AdmittedSource source,boolean requireConfirmedPackaging) {
        var unit=validateAdmittedIdentity(source);
        DeliveryPlan plan=source.deliveryPlan();Snapshot frozen=source.frozenSnapshot();
        if(source.qty()==null || source.qty().signum()<=0)throw invalid("交付数量必须大于零");
        Preview result=DeliveryFrontier.resolve(frozen,source.qty().multiply(unit.unitRate()),plan);
        if(!result.issues().isEmpty())throw invalid(result.issues().getFirst().message());
        if(requireConfirmedPackaging&&plan.packaging()==DeliveryPlan.Packaging.PENDING)throw invalid("包装安排待确认，不能继续办理");
        for(Item item:result.items())references.requireAdmittedSourceActiveGoods(item.goodsId());
        return result;
    }
    @Transactional
    public void requireCurrentAdmittedFingerprint(AdmittedSource source) { validateAdmittedIdentity(source); }
    private MasterReferenceValidationPort.ResolvedLineUnit validateAdmittedIdentity(AdmittedSource source) {
        DeliveryPlan plan=source.deliveryPlan();Snapshot frozen=source.frozenSnapshot();
        if(plan==null || frozen==null || frozen.root()==null || !Objects.equals(source.goodsId(),frozen.goodsId())
                || !Objects.equals(plan.bomFingerprint(),frozen.bomFingerprint()))
            throw new ApiException(ErrorCode.CONFLICT,"原单缺少匹配的冻结交付BOM，请回原业务受控核对");
        var unit=references.resolveAdmittedSourceGoodsUnit(source.goodsId(),source.unitId(),source.unitRate(),1);
        Snapshot current=readSnapshot(source.goodsId(),false);
        if(!Objects.equals(plan.bomFingerprint(),current.bomFingerprint()))
            throw new ApiException(ErrorCode.CONFLICT,"产品BOM或交付约束已变化，请回原单重新核对");
        return unit;
    }

    @Transactional
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:edit')")
    public Snapshot updateRule(UUID edgeId, boolean mandatory, MaterialRole role,
            List<DeliveryPlan.Operation> requiredOperations, String expectedFingerprint, UUID requestedRoot) {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<Object[]> edges = em.createNativeQuery("SELECT goods_id,component_goods_id FROM goods_bom_items WHERE id=:id AND NOT is_deleted")
                .setParameter("id", edgeId).getResultList();
        if (edges.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "BOM边不存在");
        UUID parent=uuid(edges.getFirst()[0]);
        references.requireVisibleGoods(parent); references.requireVisibleGoods(uuid(edges.getFirst()[1]));
        graphLock.acquire();
        UUID rootId=requestedRoot==null?parent:requestedRoot;
        Snapshot before=snapshot(rootId);
        if (!containsEdge(before.root(),edgeId)) throw new ApiException(ErrorCode.CONFLICT,"该BOM边不属于当前产品快照");
        if (!Objects.equals(expectedFingerprint,before.bomFingerprint()))
            throw new ApiException(ErrorCode.CONFLICT,"BOM或交付约束已变化，请刷新核对后再修改");
        String operations;
        try { operations=mapper.writeValueAsString(requiredOperations==null?List.of():requiredOperations.stream().distinct().sorted().toList()); }
        catch(Exception ex){throw invalid("工序配置无效");}
        em.createNativeQuery("""
            INSERT INTO goods_bom_delivery_rules(bom_edge_id,mandatory_assembly,material_role,required_operations)
            VALUES (:id,:mandatory,:role,CAST(:operations AS jsonb))
            ON CONFLICT(bom_edge_id) DO UPDATE SET mandatory_assembly=EXCLUDED.mandatory_assembly,
                material_role=EXCLUDED.material_role,required_operations=EXCLUDED.required_operations,updated_at=now()
            """).setParameter("id",edgeId).setParameter("mandatory",mandatory)
                .setParameter("role",role.name()).setParameter("operations",operations).executeUpdate();
        return snapshot(rootId);
    }
    private static boolean containsEdge(Node node,UUID edgeId) {
        return edgeId.equals(node.edgeId()) || node.children().stream().anyMatch(child -> containsEdge(child,edgeId));
    }

    private List<DeliveryPlan.Operation> operations(String json) {
        try { return mapper.readValue(json, mapper.getTypeFactory().constructCollectionType(List.class, DeliveryPlan.Operation.class)); }
        catch (Exception ex) { throw invalid("BOM必要工序规则无效，请联系管理员核对"); }
    }
    private String fingerprint(Object value) {
        try {
            byte[] content = mapper.writeValueAsString(value).getBytes(StandardCharsets.UTF_8);
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(content));
        } catch (Exception ex) { throw new IllegalStateException("Cannot fingerprint delivery BOM", ex); }
    }
    private static Object recipeIdentity(Node node) {
        Map<String,Object> fields = new LinkedHashMap<>();
        fields.put("path",node.path()); fields.put("goodsId",node.goodsId()); fields.put("unitId",node.unitId());
        fields.put("colorId",node.colorId()); fields.put("spec",node.spec()); fields.put("sourceType",node.sourceType());
        fields.put("qty",node.qtyExact()); fields.put("basis",node.consumptionBasis()); fields.put("output",node.basisOutputQtyExact());
        fields.put("partial",node.allowPartialPackage()); fields.put("state",node.childrenState());
        fields.put("mandatory",node.mandatoryAssembly()); fields.put("role",node.materialRole());
        fields.put("operations",node.requiredOperations().stream().sorted().toList());
        fields.put("identityIssues",node.identityIssues().stream().sorted().toList());
        fields.put("children",node.children().stream().sorted(Comparator.comparing(child -> child.edgeId().toString()))
                .map(BomDeliveryService::recipeIdentity).toList());
        return fields;
    }
    private static UUID uuid(Object value) { return value == null ? null : value instanceof UUID id ? id : UUID.fromString(value.toString()); }
    private static List<String> identityIssues(Object value){return value==null||value.toString().isBlank()?List.of():Arrays.stream(value.toString().split(",")).distinct().sorted().toList();}
    private static String string(Object value) { return value == null ? null : value.toString(); }
    private static String decimal(Object value) { return value == null ? null : new BigDecimal(value.toString()).stripTrailingZeros().toPlainString(); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
