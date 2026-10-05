package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.application.port.InventoryMovementCostReference;
import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.features.stock.weight.CapturedWeight;
import com.uten.imp.features.stock.weight.StockWeightAdjustmentRepository;
import com.uten.imp.features.stock.weight.StockWeightContextReader;
import com.uten.imp.features.stock.weight.StockWeightResolver;
import com.uten.imp.features.stock.weight.WeightSource;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.List;
import java.util.LinkedHashSet;
import java.util.Objects;
import java.util.UUID;

/**
 * 库存联动服务：单据审核时在同一事务内「写流水 + upsert 余额」。
 *
 * <p>所有出入库单据（采购/销售/领料/盘点…）
 * 统一调 {@link #recordMovement}，对用户零割裂（审核即库存变化），对系统统一入口、可审计。
 *
 * <p>幂等性：调用方负责不重复调用（单据审核状态机保证 status 仅 0→1 一次）。
 * 红冲（1→-1）由调用方以反方向 movement 冲销。
 *
 * <p>仓库用途(ADR-146): 每笔流水先按出入库类别矩阵({@link WarehouseClassMovementRule})核对落仓类别——
 * 良品业务不进出不良品仓, 调拨按调拨类型判定两端; 数据库 fn_guard_stock_movement_warehouse_class 兜底。
 * 不良品仓不参与可用量, 没有预留和安全库存, 从不良品仓出库只守非负底线。
 *
 * <p>仓库重量账(ADR-135): 重量是仓库自己的平行账, 永远不挡数量过账。每笔流水在同一把库存锁下按
 * 精确换算 > 调拨对应 > 红冲镜像 > 实称/切片 > 均重/单重估算 定出重量与来历, 余额重量整值改写,
 * 需要时先补「重量起算 / 尾差调整」行(见 weight.StockWeightResolver)。
 */
@Service
@RequiredArgsConstructor
public class StockService {

    /** movement_type 字典。 */
    public static final short TYPE_PURCHASE_RECEIPT = 1;
    public static final short TYPE_PURCHASE_RETURN = 2;
    public static final short TYPE_SALES_OUT = 3;
    public static final short TYPE_SALES_RETURN = 4;
    public static final short TYPE_CHECK_LOSS = 10;
    // 5–14 生产领退料/调拨/盘点/其它/产成品（仓库模块用，见注释）
    public static final short TYPE_SUBCONTRACT_MATERIAL_ISSUE = 15;  // 委外材料出仓 E_SOut
    public static final short TYPE_SUBCONTRACT_MATERIAL_RETURN = 16; // 委外材料退回 E_SWithDraw
    public static final short TYPE_SUBCONTRACT_RECEIPT = 17;         // 委外成品进仓 E_In（正向入库）
    public static final short TYPE_SUBCONTRACT_RETURN = 18;          // 委外成品退 E_WithDraw
    public static final short TYPE_SUBCONTRACT_WASTE = 19;           // 委外材料损耗 E_SWaste
    public static final short TYPE_SALES_OTHER_OUT = 20;             // 销售其它出库 S_OtherOut
    // ADR-131 车间内料仓盘点过账: 必须带 WorkshopMaterialBin 来源引用(本事务登记的盘点过账行)。
    public static final short TYPE_WORKSHOP_MATERIAL_CONSUME = 21;   // 内料仓盘点耗用(出; 更正时原路入)
    public static final short TYPE_WORKSHOP_MATERIAL_GAIN = 22;      // 内料仓盘盈(入; 更正时原路出)
    public static final short TYPE_WORKSHOP_APPROVED_COUNT = 23;     // 已审核内料仓期初或账面修正

    /** direction 字典。 */
    public static final short DIR_IN = 1;
    public static final short DIR_OUT = -1;

    /**
     * 红冲/纠偏/退货类出库（KS-P1-1）：这些类型的 DIR_OUT 是撤销既定入库或退供应商/委外商——
     * 货物确实在库，只守"非负底线"（available >= qty），不守 movable（balance−预留−安全）。
     * 原因：红冲/退货不应被"为其它订单预留的库存"卡死（预留是运营关注，由人解绑）。
     * 新增消耗类出库（销售出货/其它出库/委外发料/生产领料）不在本集合，仍守 movable。
     * （PURCHASE_RECEIPT/SUBCONTRACT_RECEIPT/SUBCONTRACT_MATERIAL_RETURN 的 DIR_OUT 仅出现在红冲；
     * PURCHASE_RETURN/SUBCONTRACT_RETURN 的 DIR_OUT 是退货审核；SALES_RETURN 的 DIR_OUT 是 legacy 红冲。）
     */
    private static final java.util.Set<Short> REVERSAL_RETURN_TYPES = java.util.Set.of(
            TYPE_PURCHASE_RECEIPT, TYPE_PURCHASE_RETURN, TYPE_SALES_RETURN,
            TYPE_SUBCONTRACT_MATERIAL_RETURN, TYPE_SUBCONTRACT_RECEIPT, TYPE_SUBCONTRACT_RETURN);

    /** 来源单据类型（source_doc_type）。 */
    public static final String SRC_PURCHASE_RECEIPT = "PURCHASE_RECEIPT";
    public static final String SRC_PURCHASE_RETURN = "PURCHASE_RETURN";
    public static final String SRC_SALES_SHIPMENT = "SALES_SHIPMENT";
    public static final String SRC_SALES_RETURN = "SALES_RETURN";
    public static final String SRC_SALES_OTHER_SHIPMENT = "SALES_OTHER_SHIPMENT";
    public static final String SRC_SUBCONTRACT_RECEIPT = "SUBCONTRACT_RECEIPT";
    public static final String SRC_SUBCONTRACT_RETURN = "SUBCONTRACT_RETURN";
    public static final String SRC_SUBCONTRACT_MATERIAL_ISSUE = "SUBCONTRACT_MATERIAL_ISSUE";
    public static final String SRC_SUBCONTRACT_MATERIAL_RETURN = "SUBCONTRACT_MATERIAL_RETURN";
    public static final String SRC_SUBCONTRACT_WASTE = "SUBCONTRACT_WASTE";
    /** 内料仓盘点过账: source_doc_id = 盘点单, source_item_id = 期间用量行。 */
    public static final String SRC_WORKSHOP_MATERIAL_COUNT = "WORKSHOP_MATERIAL_COUNT";

    private final StockMovementRepository movementRepo;
    private final StockBalanceRepository balanceRepo;
    private final TxSessionVars tx;
    private final InventoryMutationLock inventoryLock;
    private final com.uten.imp.features.stock.valuation.StockValuationCoordinator valuation;
    private final GoodsOwningWarehouseSyncService owningWarehouseSync;
    /**
     * ADR-103 委外路线 B「子件到货即解锁」的唯一唤醒口: 库存内核每记一笔入库方向流水就回头
     * 叫醒等这批货的委外出仓计划行(ADR-017 跨 feature 只经 application.port)。用 ObjectProvider
     * 是因为纯单测手工 new 时没有委外模块; 生产环境由 SubcontractMaterialPlanService 实现。
     */
    private final ObjectProvider<SubcontractOutboundWakePort> subcontractOutboundWake;
    /**
     * ADR-135 重量上下文(重量系数/红冲镜像/调拨对应/单重)。手工 new 的纯单测没有它时只按余额快照算
     * (不精确换算、不镜像、不估算单重), 数量照常过账。
     */
    private final ObjectProvider<StockWeightContextReader> weightContexts;
    /** ADR-135 只改重量的调整流水(起算/尾差); 纯单测没有这张表时不写。 */
    private final ObjectProvider<StockWeightAdjustmentRepository> weightAdjustments;

    /**
     * Pre-locks all dimensions of a multi-line document in stable order.
     * Callers should invoke this once before their movement loop.
     */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void lockInventory(Collection<InventoryKey> keys) {
        inventoryLock.lockAll(keys);
    }
    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void bindProductionMovements(UUID event,java.util.Map<UUID,UUID> movements){
        valuation.bindProductionMovements(event,movements);
    }

    /**
     * 出入库请求值对象。qty 为基本单位量（已乘 unit_rate）；amountLocal 为本币金额。
     *
     * <p>weight 是调用方带来的重量证据(千克): 仓库实称 {@link CapturedWeight#measured} 或来源单据实称的累计切片
     * {@link CapturedWeight#slice}; null = 没有证据, 由库存账按规则推算。红冲一律传 null(按原流水镜像)。
     */
    public record MovementRequest(
            OffsetDateTime transactionDate,
            short movementType,
            String sourceDocType,
            UUID sourceDocId,
            UUID sourceItemId,
            UUID goodsId,
            UUID colorId,
            UUID warehouseId,
            short direction,
            BigDecimal qty,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal amountLocal,
            String remark,
            CapturedWeight weight,
            InventoryMovementCostReference costReference) {

        /** 没有成本来源引用的出入库。 */
        public MovementRequest(OffsetDateTime transactionDate, short movementType, String sourceDocType,
                UUID sourceDocId, UUID sourceItemId, UUID goodsId, UUID colorId, UUID warehouseId, short direction,
                BigDecimal qty, UUID unitId, BigDecimal unitRate, BigDecimal amountLocal, String remark,
                CapturedWeight weight) {
            this(transactionDate, movementType, sourceDocType, sourceDocId, sourceItemId, goodsId, colorId,
                    warehouseId, direction, qty, unitId, unitRate, amountLocal, remark, weight, null);
        }
    }

    /**
     * 过账结果: 流水 id, 以及库存账定下的本笔重量(千克, null = 未知)与来历; replayed = 估值幂等重放(未重复记账)。
     */
    public record PostedMovement(UUID movementId, BigDecimal weightKg, WeightSource weightSource, boolean replayed) {
    }

    /**
     * 记一笔出入库：流水 + 余额（同事务，调用方需 @Transactional）。
     *
     * @param req 方向已体现在 direction（+1/-1），qty/amountLocal 传正数
     */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public PostedMovement recordMovement(MovementRequest req) {
        return recordMovementInternal(null,req);
    }

    /** Reserved for a real IQC item which is inserted before its deferred physical FK is completed. */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public PostedMovement recordMovementWithId(UUID reservedMovementId,MovementRequest req){
        if(reservedMovementId==null||req==null||!(req.costReference() instanceof InventoryMovementCostReference.ProcurementStockIn stock)
                ||stock.stockInItemId()==null||!stock.stockInItemId().equals(req.sourceItemId()))
            throw new IllegalArgumentException("a reserved movement requires its exact procurement stock-in reference");
        return recordMovementInternal(reservedMovementId,req);
    }

    private PostedMovement recordMovementInternal(UUID reservedMovementId,MovementRequest req){
        tx.bind();
        if (req == null || req.goodsId() == null || req.warehouseId() == null
                || req.sourceDocType() == null || req.sourceDocType().isBlank()) {
            throw new IllegalArgumentException("inventory movement identity is incomplete");
        }
        if (req.direction() != DIR_IN && req.direction() != DIR_OUT) {
            throw new IllegalArgumentException("inventory movement direction must be +1 or -1");
        }
        if (req.qty() == null || req.qty().signum() <= 0) {
            throw new IllegalArgumentException("inventory movement quantity must be positive");
        }
        if (req.weight() != null && req.weight().kg() != null && req.weight().kg().signum() < 0) {
            throw new IllegalArgumentException("inventory movement weight must not be negative");
        }
        InventoryMovementCostReference.WorkshopMaterialBin bin = workshopMaterialBin(req);
        WarehouseClass warehouseClass = requireWarehouseClass(req);
        boolean defectiveWarehouse = warehouseClass.defective();
        // Re-entrant when the top-level document already batch-locked its keys;
        // mandatory as a safe fallback for future single-movement callers.
        inventoryLock.lock(new InventoryKey(req.goodsId(), req.colorId()));
        if (req.direction() == DIR_IN) {
            // The prefix has already frozen all inventory keys for multi-document commands.
            // Lock their goods rows once in PostgreSQL order, independently of display/line order.
            owningWarehouseSync.lockForPosting(inventoryLock);
        }
        // ADR-131: 内料仓的进出只认本事务里内料仓服务登记的单据或盘点过账行, 不接受调用方自报来源。
        if (bin != null && !Boolean.TRUE.equals(balanceRepo.workshopMaterialBinMovementAuthorized(
                bin.kind().name(), bin.sourceId(), req.sourceDocId(), req.sourceItemId(),
                req.warehouseId(), req.goodsId(), req.colorId(), req.qty()))) {
            throw new ApiException(ErrorCode.CONFLICT, "内料仓出入库缺少本次登记的来源, 请刷新后重试");
        }
        var physicalRows=balanceRepo.readPhysicalSnapshot(req.warehouseId(),req.goodsId(),req.colorId());
        if(physicalRows.size()>1)throw new ApiException(ErrorCode.CONFLICT,"库存维度存在重复余额，请先核对");
        var physical=physicalRows.isEmpty()?null:physicalRows.getFirst();
        if (req.direction() == DIR_OUT) {
            BigDecimal available = physical == null ? BigDecimal.ZERO : physical.getQty();
            if (available.compareTo(req.qty()) < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "目标仓库存不足：当前 " + available.stripTrailingZeros().toPlainString()
                                + "，本次出库 " + req.qty().stripTrailingZeros().toPlainString());
            }
            // 重量永远不挡数量过账(ADR-135): 实称比账面重就按实称出, 余额用尾差行纠正。
            // A physical count loss records reality and must not be blocked by
            // an operational reservation policy. Every normal outbound path,
            // including returns, transfers and subcontract issues, may only
            // consume stock left after active reservations and safety stock.
            // KS-P1-1: 红冲/退货类 DIR_OUT 同样不守 movable（只守上方非负底线）——撤销入库/退供应商
            // 不应被他人预留卡死；非负底线已防真实负库存。
            // ADR-131: 内料仓作为出库方(退回调出、其它耗用、盘点耗用、盘盈冲回)只守非负底线——
            // 内料仓不参与公共可用量, 没有别人的预留, 安全库存也不适用于车间料架; 叶仓发到内料仓
            // 的调出一侧只扣有效预留、不扣安全库存(料仍在本厂, 只是换了存放位置)。
            boolean binIssue = bin != null
                    && bin.kind() == InventoryMovementCostReference.WorkshopMaterialBinKind.ISSUE_OUT;
            // ADR-146: 不良品仓不参与可用量(上面没有任何预留, 安全库存只管良品), 出库只守非负底线。
            // 「转不良品仓」的调出一侧与盘亏一样是在记录事实(这些货已经判为不良, 不再是良品):
            // 不能被预留或安全库存挡住, 只守非负底线; 因此失去实物支撑的预留由建单方在同一事务里列出提醒。
            if (req.movementType() != TYPE_CHECK_LOSS
                    && !REVERSAL_RETURN_TYPES.contains(req.movementType())
                    && !defectiveWarehouse
                    && !warehouseClass.quarantineLeg()
                    && (bin == null || binIssue)) {
                boolean allocatedProductionIssue = false;
                if (req.costReference() instanceof InventoryMovementCostReference.WorkshopReturn returned) {
                    if (!Boolean.TRUE.equals(balanceRepo.workshopReturnOutboundAuthorized(returned.requestItemId(),req.sourceDocId(),
                            req.sourceItemId(),req.warehouseId(),req.qty(),returned.kind().name())))
                        throw new ApiException(ErrorCode.CONFLICT,"退仓库存缺少本次原来源移交或反向准备，不能使用其他任务的物料");
                    allocatedProductionIssue = true;
                }
                if (req.costReference() instanceof InventoryMovementCostReference.ProductionMaterialEvent event) {
                    if (req.movementType() != 5 || !"STOCK_DOC".equals(req.sourceDocType()) || event.eventId() == null) {
                        throw new ApiException(ErrorCode.CONFLICT, "生产领料流水与领料记录不匹配");
                    }
                    BigDecimal posted = balanceRepo.unboundProductionIssueQuantity(event.eventId(), req.sourceDocId(),
                            req.sourceItemId(), req.warehouseId(), req.goodsId(), req.colorId(), req.unitId(),
                            req.unitRate() == null ? BigDecimal.ONE : req.unitRate());
                    if (posted == null || posted.compareTo(req.qty()) != 0) {
                        throw new ApiException(ErrorCode.CONFLICT, "本次领料没有对应的已扣预留记录，请刷新后重试");
                    }
                    allocatedProductionIssue = true;
                }
                BigDecimal movable = allocatedProductionIssue || binIssue
                        ? balanceRepo.warehouseUnreservedBase(req.warehouseId(), req.goodsId(), req.colorId())
                        : balanceRepo.warehouseAvailableBase(req.warehouseId(), req.goodsId(), req.colorId());
                if (movable == null) movable = BigDecimal.ZERO;
                if (movable.compareTo(req.qty()) < 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            (allocatedProductionIssue ? "本仓剩余可领数量不足：当前 "
                                    : binIssue ? "本仓可发到车间内料仓的数量不足(已扣硬预留)：当前 "
                                    : "可动用库存不足(已扣硬预留和安全库存)：当前 ")
                                    + movable.stripTrailingZeros().toPlainString()
                                    + "，本次出库 "
                                    + req.qty().stripTrailingZeros().toPlainString());
                }
            }
        }
        OffsetDateTime ts = req.transactionDate() != null ? req.transactionDate() : OffsetDateTime.now();

        StockMovement m = new StockMovement();
        // 预留流水 UUID 由调用方当场随机生成(IQC 入库行先登记它, 延迟外键在提交时核对);
        // 撞上已存在的主键只可能是编码错误, 交给主键唯一约束拒绝, 不再为它先按主键查一次(ADR-107)。
        if(reservedMovementId!=null)m.setId(reservedMovementId);
        m.setTransactionDate(ts);
        m.setMovementType(req.movementType());
        m.setSourceDocType(req.sourceDocType());
        m.setSourceDocId(req.sourceDocId());
        m.setSourceItemId(req.sourceItemId());
        m.setGoodsId(req.goodsId());
        m.setColorId(req.colorId());
        m.setWarehouseId(req.warehouseId());
        m.setDirection(req.direction());
        m.setQty(req.qty());
        m.setUnitId(req.unitId());
        m.setUnitRate(req.unitRate());
        BigDecimal quantityBefore=physical==null?BigDecimal.ZERO:physical.getQty();
        var valued=valuation.value(m.getId(),req,quantityBefore,ts);
        if(valued.replayed())return replayedMovement(valued.movementId());
        m.setAmountLocal(valued.knownValueLocal());
        // ADR-135 仓库重量账: 估值重放检查之后才定重量; 起算/尾差行先写(ledger_seq 在流水之前),
        // 流水行记含纠正的最终余额重量。
        StockWeightResolver.WeightResolution weight =
                StockWeightResolver.resolve(weightContext(req, physical), req);
        writeWeightAdjustments(m, req, ts, weight.before());
        m.setWeight(weight.weightKg());
        m.setWeightSource(weight.source() == null ? null : weight.source().name());
        m.setBalanceWeightAfter(weight.balanceWeightAfter());
        m.setRemark(req.remark());
        movementRepo.save(m);

        BigDecimal dir = BigDecimal.valueOf(req.direction());
        BigDecimal signedQty = req.qty().multiply(dir);
        BigDecimal signedAmt = valued.knownValueLocal().multiply(dir);
        balanceRepo.upsertBalance(req.warehouseId(), req.goodsId(), req.colorId(),
                signedQty, signedAmt, weight.balanceWeightAfter(), weight.estimatedAfter(), ts);
        // 货品「归属仓」单一事实源（V590）：任何入库自动回写为最新入库仓。
        // 出库/红冲不翻转；值没变不写。见 GoodsOwningWarehouseSyncService。
        if (req.direction() == DIR_IN) {
            owningWarehouseSync.syncOnInbound(req.goodsId(), req.warehouseId());
            // The source document still has to attribute qualified stock or restore
            // reversed custody after this movement. Wake before commit, after those
            // facts exist, so another order cannot reserve the transient public balance.
            enqueueSubcontractWake(new SubcontractOutboundWakePort.StockedDimension(
                    req.goodsId(), req.colorId(), req.warehouseId()));
        }
        return new PostedMovement(m.getId(), weight.weightKg(), weight.source(), false);
    }

    /**
     * 这笔流水所在仓的类别事实: 是不是不良品仓; 是不是「转不良品仓」的调出一侧(从良品仓移走判为不良的货)。
     */
    private record WarehouseClass(boolean defective, boolean quarantineLeg) {
        static final WarehouseClass GOOD = new WarehouseClass(false, false);
    }

    /**
     * ADR-146 出入库类别校验: 按矩阵核对这笔流水能不能落在这个仓, 不能就给出中文原因。
     * 返回这个仓的类别事实(出库可动量口径要用)。手工 new 的纯单测查不到仓时按良品仓处理。
     */
    private WarehouseClass requireWarehouseClass(MovementRequest req) {
        boolean transferLeg = (req.movementType() == 7 || req.movementType() == 8)
                && com.uten.imp.features.stock.StockDocService.SRC_STOCK_DOC.equals(req.sourceDocType());
        List<StockBalanceRepository.WarehouseClassFacts> rows = balanceRepo.warehouseClassFacts(
                req.warehouseId(), transferLeg ? req.sourceDocId() : null);
        if (rows == null || rows.isEmpty()) return WarehouseClass.GOOD;
        StockBalanceRepository.WarehouseClassFacts facts = rows.getFirst();
        boolean defective = Boolean.TRUE.equals(facts.getDefective());
        WarehouseClassMovementRule.TransferSide transfer = facts.getTransferKind() == null ? null
                : new WarehouseClassMovementRule.TransferSide(facts.getTransferKind(),
                        facts.getFromId() == null ? null : Boolean.TRUE.equals(facts.getFromDefective()),
                        facts.getToId() == null ? null : Boolean.TRUE.equals(facts.getToDefective()),
                        req.warehouseId().equals(facts.getFromId()) || req.warehouseId().equals(facts.getToId()));
        String violation = WarehouseClassMovementRule.violation(req.movementType(), defective, transfer);
        if (violation != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    WarehouseClassMovementRule.message(violation, facts.getName(), req.movementType()));
        }
        boolean quarantineLeg = transfer != null && "TO_DEFECTIVE".equals(transfer.kind())
                && req.direction() == DIR_OUT && !defective && req.warehouseId().equals(facts.getFromId());
        return new WarehouseClass(defective, quarantineLeg);
    }

    /** 估值幂等重放: 不再记账, 按已落库的原流水回报重量。 */
    private PostedMovement replayedMovement(UUID movementId) {
        StockMovement stored = movementRepo.findById(movementId).orElse(null);
        if (stored == null) return new PostedMovement(movementId, null, null, true);
        WeightSource source = WeightSource.fromColumn(stored.getWeightSource());
        return new PostedMovement(movementId, stored.getWeight(),
                source == null && stored.getWeight() != null ? WeightSource.MEASURED : source, true);
    }

    /** 本维度的重量上下文; 没有读取器(手工 new 的纯单测)时只用余额快照。 */
    private StockWeightResolver.WeightContext weightContext(
            MovementRequest req, StockBalanceRepository.PhysicalSnapshot physical) {
        BigDecimal qty = physical == null ? BigDecimal.ZERO : physical.getQty();
        BigDecimal weight = physical == null ? null : physical.getWeight();
        boolean estimated = physical != null && Boolean.TRUE.equals(physical.getWeightEstimated());
        StockWeightContextReader reader = weightContexts.getIfAvailable();
        return reader == null
                ? StockWeightResolver.WeightContext.balanceOnly(qty, weight, estimated, physical != null)
                : reader.read(req, qty, weight, estimated, physical != null);
    }

    private void writeWeightAdjustments(StockMovement m, MovementRequest req, OffsetDateTime ts,
                                        List<StockWeightResolver.AdjustmentDraft> drafts) {
        if (drafts.isEmpty()) return;
        StockWeightAdjustmentRepository repository = weightAdjustments.getIfAvailable();
        if (repository == null) return;
        for (StockWeightResolver.AdjustmentDraft draft : drafts) {
            repository.insert(new StockWeightAdjustmentRepository.NewAdjustment(
                    draft.kind(), ts, req.warehouseId(), req.goodsId(), req.colorId(),
                    draft.before(), draft.after(), m.getId(), null,
                    req.sourceDocType(), req.sourceDocId(), req.sourceItemId(), null, null, null));
        }
    }

    /**
     * ADR-131: 内料仓来源引用只接受与流水类型、方向、来源类型一致的组合; 21/22 型必须带引用。
     * 不一致是调用方编码错误(不是用户输入), 直接拒绝。
     */
    private static InventoryMovementCostReference.WorkshopMaterialBin workshopMaterialBin(MovementRequest req) {
        boolean countMovement = req.movementType() == TYPE_WORKSHOP_MATERIAL_CONSUME
                || req.movementType() == TYPE_WORKSHOP_MATERIAL_GAIN
                || req.movementType() == TYPE_WORKSHOP_APPROVED_COUNT;
        if (!(req.costReference() instanceof InventoryMovementCostReference.WorkshopMaterialBin bin)) {
            if (countMovement) {
                throw new IllegalArgumentException(
                        "workshop material count movements require their registered count posting reference");
            }
            return null;
        }
        if (bin.sourceId() == null || bin.kind() == null) {
            throw new IllegalArgumentException("workshop material bin reference is incomplete");
        }
        boolean stockDocument = "STOCK_DOC".equals(req.sourceDocType());
        boolean countPosting = SRC_WORKSHOP_MATERIAL_COUNT.equals(req.sourceDocType());
        boolean matches = switch (bin.kind()) {
            // 8 = 调拨调出, 12 = 其它出库; 内料仓单据的调入一侧不带引用。
            case ISSUE_OUT, RETURN_OUT -> stockDocument && req.movementType() == 8 && req.direction() == DIR_OUT;
            case OTHER_ISSUE_OUT -> stockDocument && req.movementType() == 12 && req.direction() == DIR_OUT;
            case CONSUME -> countPosting && req.movementType() == TYPE_WORKSHOP_MATERIAL_CONSUME && req.direction() == DIR_OUT;
            case CONSUME_REVERSE -> countPosting && req.movementType() == TYPE_WORKSHOP_MATERIAL_CONSUME && req.direction() == DIR_IN;
            case GAIN -> countPosting && req.movementType() == TYPE_WORKSHOP_MATERIAL_GAIN && req.direction() == DIR_IN;
            case GAIN_REVERSE -> countPosting && req.movementType() == TYPE_WORKSHOP_MATERIAL_GAIN && req.direction() == DIR_OUT;
            case COUNT_OPENING, COUNT_ADJUSTMENT_IN -> "STOCK_COUNT_REQUEST".equals(req.sourceDocType())
                    && req.movementType() == TYPE_WORKSHOP_APPROVED_COUNT && req.direction() == DIR_IN;
            case COUNT_ADJUSTMENT_OUT -> "STOCK_COUNT_REQUEST".equals(req.sourceDocType())
                    && req.movementType() == TYPE_WORKSHOP_APPROVED_COUNT && req.direction() == DIR_OUT;
        };
        if (!matches) {
            throw new IllegalArgumentException(
                    "workshop material bin reference does not match the movement type, direction and source");
        }
        return bin;
    }

    private void enqueueSubcontractWake(SubcontractOutboundWakePort.StockedDimension dimension) {
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            // Manually constructed unit-test services have no transaction interceptor.
            deliverSubcontractWake(List.of(dimension));
            return;
        }
        SubcontractStockInWake pending = TransactionSynchronizationManager.getSynchronizations().stream()
                .filter(SubcontractStockInWake.class::isInstance)
                .map(SubcontractStockInWake.class::cast).findFirst().orElse(null);
        if (pending == null) {
            pending = new SubcontractStockInWake();
            TransactionSynchronizationManager.registerSynchronization(pending);
        }
        pending.dimensions.add(dimension);
    }

    private void deliverSubcontractWake(List<SubcontractOutboundWakePort.StockedDimension> dimensions) {
        subcontractOutboundWake.ifAvailable(port -> port.wakeOutboundAfterStockIn(dimensions));
    }

    private final class SubcontractStockInWake implements TransactionSynchronization {
        private final LinkedHashSet<SubcontractOutboundWakePort.StockedDimension> dimensions = new LinkedHashSet<>();

        @Override
        public void beforeCommit(boolean readOnly) {
            // Still inside the original transaction: failures roll back stock and
            // provenance together. Rollbacks never run this callback.
            deliverSubcontractWake(List.copyOf(dimensions));
        }
    }
}
