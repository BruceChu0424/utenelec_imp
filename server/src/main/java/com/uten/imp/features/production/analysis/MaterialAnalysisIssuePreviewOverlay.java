package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import com.uten.imp.application.port.PreplanAnalysisPegPort.PreviewPlanTransfer;
import com.uten.imp.application.port.PreplanAnalysisPegPort.PreviewPublicReservation;
import static com.uten.imp.features.production.analysis.MaterialAnalysisService.*;

/**
 * 下达预览(ADR-116)的内存投影: 「真实下达之后」与当前库内快照之间的全部差异。
 *
 * <p>它只在一次只读预览里存活, 不落库、不取锁。刷新引擎与视图构建器的几个读取入口
 * (来源行、物料行、计划批次、父件供给承诺、顶层供给行)按它把差异叠到库内事实上,
 * 于是预览与真实下达后的 GET 详情走<b>同一套</b>投影与推导代码, 不存在第二套口径。</p>
 *
 * <p>差异分两类:
 * <ul>
 *   <li>下达本身会写的事实: 本批计划归需求量/公共备货量(来源行 submitted/approved/
 *       公共备货), 计划批次, 锚点父件的计划产出与内部承诺, 自制锚点配额增长;</li>
 *   <li>刷新会写回的快照: 物料行数量列、来源行齐套列、顶层供给行数量列。</li>
 * </ul>
 * 真实命令路径恒用 {@link #NONE}, 各读取入口此时与改造前逐字等价。</p>
 */
final class MaterialAnalysisIssuePreviewOverlay {

    /** 真实命令与 GET 详情: 不叠加任何差异。 */
    static final MaterialAnalysisIssuePreviewOverlay NONE = new MaterialAnalysisIssuePreviewOverlay(true);

    /** 来源行(分析行)的数量差; 齐套列为 null 表示沿用库内值。 */
    record SourceDelta(BigDecimal requested, BigDecimal submitted, BigDecimal approved, BigDecimal surplus,
                       BigDecimal readyNow, BigDecimal readyByDate, BigDecimal readyStart,
                       BigDecimal readyFinish, BigDecimal readyShip) {
        static final SourceDelta ZERO = new SourceDelta(BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, null, null, null, null, null);

        SourceDelta plus(BigDecimal requestedDelta, BigDecimal submittedDelta,
                         BigDecimal approvedDelta, BigDecimal surplusDelta) {
            return new SourceDelta(requested.add(requestedDelta), submitted.add(submittedDelta),
                    approved.add(approvedDelta), surplus.add(surplusDelta),
                    readyNow, readyByDate, readyStart, readyFinish, readyShip);
        }

        SourceDelta withReady(BigDecimal now, BigDecimal byDate, BigDecimal start,
                              BigDecimal finish, BigDecimal ship) {
            return new SourceDelta(requested, submitted, approved, surplus, now, byDate, start, finish, ship);
        }
    }

    /** 刷新写回物料行的一整组数量列(与 NODE_ALLOCATION_UPDATE_SQL 的列一一对应)。 */
    record NodeSnapshot(BigDecimal required, BigDecimal available, BigDecimal allocated,
                        BigDecimal reserved, BigDecimal safety, BigDecimal inbound, BigDecimal shortage,
                        LocalDate expectedReadyDate, boolean lowerPending) {
    }

    /** 顶层供给行刷新写回的数量列(不含到货日期与下层未齐标记, 那两列根刷新不写)。 */
    record RootSnapshot(BigDecimal required, BigDecimal available, BigDecimal reserved, BigDecimal safety,
                        BigDecimal allocated, BigDecimal shortage, BigDecimal inbound) {
    }

    private final boolean frozen;
    private final Map<UUID, SourceDelta> sources = new HashMap<>();
    private final Map<String, BigDecimal> plannedOutputByNode = new HashMap<>();
    private final Map<String, BigDecimal> internalCommitmentByNode = new HashMap<>();
    private final Map<String, List<BigDecimal>> appendedBatches = new HashMap<>();
    private final Map<UUID, BigDecimal> grownPlanBatches = new HashMap<>();
    private final Map<UUID, BigDecimal> openPlanQtyBySource = new HashMap<>();
    private final List<PreviewPlanTransfer> transfers = new ArrayList<>();
    private final Map<UUID, MaterialDimension> transferDimensions = new HashMap<>();
    private final List<PreviewPublicReservation> publicReservations = new ArrayList<>();
    private final Map<WarehouseMaterialDimension, BigDecimal> formalReservations = new HashMap<>();
    private final Map<WarehouseMaterialDimension, BigDecimal> transferredOwned = new HashMap<>();
    private final Map<WarehouseMaterialDimension, BigDecimal> transferredQualified = new HashMap<>();
    private final Map<UUID, BigDecimal> transferredByMaterial = new HashMap<>();
    private final Map<UUID, BigDecimal> transferredByEntitlement = new HashMap<>();
    private final List<FormalMaterialCoverage> formalCoverage = new ArrayList<>();
    private final List<com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.PreviewReceipt> receipts = new ArrayList<>();
    private final Map<UUID, BigDecimal> formalParentOutputs = new HashMap<>();
    private Map<String, NodeSnapshot> nodes = Map.of();
    private Map<UUID, RootSnapshot> roots = Map.of();

    private MaterialAnalysisIssuePreviewOverlay(boolean frozen) {
        this.frozen = frozen;
    }

    static MaterialAnalysisIssuePreviewOverlay create() {
        return new MaterialAnalysisIssuePreviewOverlay(false);
    }

    boolean isNone() {
        return this == NONE;
    }

    private void requireMutable() {
        if (frozen) throw new IllegalStateException("NONE overlay is immutable");
    }

    // ── 下达本身会写的事实 ──────────────────────────────────────────────

    void addSourceQuantities(UUID sourceId, BigDecimal requested, BigDecimal submitted,
                             BigDecimal approved, BigDecimal surplus) {
        requireMutable();
        sources.merge(sourceId, SourceDelta.ZERO.plus(requested, submitted, approved, surplus),
                (left, right) -> left.plus(right.requested(), right.submitted(),
                        right.approved(), right.surplus()));
    }

    void addPlannedOutput(String nodeRef, BigDecimal qty) {
        requireMutable();
        plannedOutputByNode.merge(nodeRef, qty, BigDecimal::add);
    }

    void addInternalCommitment(String nodeRef, BigDecimal qty) {
        requireMutable();
        internalCommitmentByNode.merge(nodeRef, qty, BigDecimal::add);
    }

    /** 新计划 = 该键下追加一批(计划按建立时间排序, 新计划恒在最后)。 */
    void appendBatch(String batchKey, BigDecimal qty) {
        requireMutable();
        appendedBatches.computeIfAbsent(batchKey, ignored -> new ArrayList<>()).add(qty);
    }

    /** ADR-104 并入: 既有计划的那一批原地加量。 */
    void growPlanBatch(UUID planId, BigDecimal qty) {
        requireMutable();
        grownPlanBatches.merge(planId, qty, BigDecimal::add);
    }

    /** 顶层供给行的「未完工计划量」(根刷新里当作在途)。 */
    void addOpenPlanQty(UUID sourceId, BigDecimal baseQty) {
        requireMutable();
        openPlanQtyBySource.merge(sourceId, baseQty, BigDecimal::add);
    }

    // ── 刷新投影结果 ───────────────────────────────────────────────────

    void replaceSnapshots(Map<String, NodeSnapshot> nodeSnapshots, Map<UUID, BigDecimal[]> readyBySource,
                          Map<UUID, RootSnapshot> rootSnapshots) {
        requireMutable();
        nodes = Map.copyOf(nodeSnapshots);
        roots = Map.copyOf(rootSnapshots);
        sources.replaceAll((id, delta) -> delta.withReady(null, null, null, null, null));
        readyBySource.forEach((id, ready) -> sources.merge(id,
                SourceDelta.ZERO.withReady(ready[0], ready[1], ready[2], ready[3], ready[4]),
                (left, right) -> left.withReady(ready[0], ready[1], ready[2], ready[3], ready[4])));
    }

    // ── 读取入口 ───────────────────────────────────────────────────────

    SourceDelta source(UUID sourceId) {
        return sources.get(sourceId);
    }

    BigDecimal plannedOutput(String nodeRef) {
        return plannedOutputByNode.getOrDefault(nodeRef, BigDecimal.ZERO);
    }

    BigDecimal internalCommitment(String nodeRef) {
        return internalCommitmentByNode.getOrDefault(nodeRef, BigDecimal.ZERO);
    }

    Map<String, BigDecimal> plannedOutputByNode() {
        return plannedOutputByNode;
    }

    Map<String, BigDecimal> internalCommitmentByNode() {
        return internalCommitmentByNode;
    }

    Map<String, List<BigDecimal>> appendedBatches() {
        return appendedBatches;
    }

    BigDecimal grownPlanBatch(UUID planId) {
        return grownPlanBatches.get(planId);
    }

    Map<UUID, BigDecimal> openPlanQtyBySource() {
        return openPlanQtyBySource;
    }

    List<PreviewPlanTransfer> transfers() { return List.copyOf(transfers); }
    MaterialDimension transferDimension(UUID demandId) { return transferDimensions.get(demandId); }
    List<PreviewPublicReservation> publicReservations() { return List.copyOf(publicReservations); }
    List<FormalMaterialCoverage> formalCoverage() { return List.copyOf(formalCoverage); }
    List<com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.PreviewReceipt> receipts() { return List.copyOf(receipts); }
    void addReceipt(MaterialDimension dimension,com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.PreviewReceipt receipt) {
        requireMutable(); receipts.add(receipt); addReservation(dimension,receipt.warehouseId(),receipt.qty());
    }
    BigDecimal formalParentOutput(UUID demand) { return formalParentOutputs.get(demand); }
    void updateFormalParentOutput(UUID demand,BigDecimal output) { requireMutable(); formalParentOutputs.put(demand,output); }
    boolean hasFormalProjection() { return !formalCoverage.isEmpty() || !formalParentOutputs.isEmpty(); }
    BigDecimal transferredMaterial(UUID material) { return transferredByMaterial.getOrDefault(material, BigDecimal.ZERO); }
    BigDecimal transferredEntitlement(UUID event) { return transferredByEntitlement.getOrDefault(event, BigDecimal.ZERO); }
    BigDecimal ownedTransferred(WarehouseMaterialDimension key) { return transferredOwned.getOrDefault(key, BigDecimal.ZERO); }
    BigDecimal qualifiedTransferred(WarehouseMaterialDimension key) { return transferredQualified.getOrDefault(key, BigDecimal.ZERO); }
    BigDecimal formalReserved(WarehouseMaterialDimension key) { return formalReservations.getOrDefault(key, BigDecimal.ZERO); }
    BigDecimal publicReservationChange(WarehouseMaterialDimension key) {
        return formalReserved(key).subtract(ownedTransferred(key));
    }
    BigDecimal publicReservationChange(UUID warehouse, UUID goods, UUID color) {
        return publicReservations.stream().filter(value -> value.warehouseId().equals(warehouse)
                        && value.goodsId().equals(goods) && java.util.Objects.equals(value.colorId(), color))
                .map(PreviewPublicReservation::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    void addReservation(MaterialDimension dimension, UUID warehouse, BigDecimal quantity) {
        requireMutable();
        formalReservations.merge(new WarehouseMaterialDimension(warehouse, dimension), quantity, BigDecimal::add);
        publicReservations.add(new PreviewPublicReservation(warehouse, dimension.goodsId(), dimension.colorId(), quantity));
    }

    void addTransfer(MaterialDimension dimension, PreviewPlanTransfer transfer) {
        requireMutable();
        transfers.add(transfer);
        transferDimensions.put(transfer.demandId(), dimension);
        WarehouseMaterialDimension key = new WarehouseMaterialDimension(transfer.warehouseId(), dimension);
        transferredOwned.merge(key, transfer.qty(), BigDecimal::add);
        if (transfer.qualified()) transferredQualified.merge(key, transfer.qty(), BigDecimal::add);
        if (transfer.beneficiaryMaterialId() != null) transferredByMaterial.merge(
                transfer.beneficiaryMaterialId(), transfer.qty(), BigDecimal::add);
        if (transfer.sourceEntitlementEventId() != null) transferredByEntitlement.merge(
                transfer.sourceEntitlementEventId(), transfer.qty(), BigDecimal::add);
        // A legacy untracked reservation can be released in one leaf and allocated in another.
        publicReservations.add(new PreviewPublicReservation(transfer.warehouseId(), dimension.goodsId(),
                dimension.colorId(), transfer.qty().negate()));
    }

    void addFormalCoverage(FormalMaterialCoverage coverage) {
        requireMutable(); formalCoverage.add(coverage);
    }

    NodeSnapshot node(String nodeRef) {
        return nodes.get(nodeRef);
    }

    Map<String, NodeSnapshot> nodes() {
        return nodes;
    }

    RootSnapshot root(UUID materialId) {
        return roots.get(materialId);
    }
}
