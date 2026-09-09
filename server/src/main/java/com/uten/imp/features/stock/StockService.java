package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.application.port.InventoryMovementCostReference;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collection;
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

    private final StockMovementRepository movementRepo;
    private final StockBalanceRepository balanceRepo;
    private final TxSessionVars tx;
    private final InventoryMutationLock inventoryLock;
    private final com.uten.imp.features.stock.valuation.StockValuationCoordinator valuation;

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

    /** 出入库请求值对象。qty 为基本单位量（已乘 unit_rate）；amountLocal 为本币金额。
     *  weight 为本次流水切片的实际总重量，不乘 unit_rate；null=来源未提供/不维护重量。
     *  weightUnitId 是 V442 显式重量单位；旧来源尚未迁移时允许为空。 */
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
            BigDecimal weight,
            UUID weightUnitId,
            InventoryMovementCostReference costReference) {

        public MovementRequest(OffsetDateTime transactionDate,short movementType,String sourceDocType,
                UUID sourceDocId,UUID sourceItemId,UUID goodsId,UUID colorId,UUID warehouseId,short direction,
                BigDecimal qty,UUID unitId,BigDecimal unitRate,BigDecimal amountLocal,String remark,
                BigDecimal weight,UUID weightUnitId){
            this(transactionDate,movementType,sourceDocType,sourceDocId,sourceItemId,goodsId,colorId,warehouseId,direction,
                    qty,unitId,unitRate,amountLocal,remark,weight,weightUnitId,null);
        }

        /** 兼容已传重量但尚未传 V442 显式重量单位的调用方。 */
        public MovementRequest(
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
                BigDecimal weight) {
            this(transactionDate, movementType, sourceDocType, sourceDocId, sourceItemId,
                    goodsId, colorId, warehouseId, direction, qty, unitId, unitRate,
                    amountLocal, remark, weight, null);
        }

        /** 兼容旧签名（无重量）：weight=null，余额重量保持不变。 */
        public MovementRequest(
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
                String remark) {
            this(transactionDate, movementType, sourceDocType, sourceDocId, sourceItemId,
                    goodsId, colorId, warehouseId, direction, qty, unitId, unitRate,
                    amountLocal, remark, null, null);
        }
    }

    /**
     * 记一笔出入库：流水 + 余额（同事务，调用方需 @Transactional）。
     *
     * @param req 方向已体现在 direction（+1/-1），qty/amountLocal 传正数
     */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public UUID recordMovement(MovementRequest req) {
        return recordMovementInternal(null,req);
    }

    /** Reserved for a real IQC item which is inserted before its deferred physical FK is completed. */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public UUID recordMovementWithId(UUID reservedMovementId,MovementRequest req){
        if(reservedMovementId==null||req==null||!(req.costReference() instanceof InventoryMovementCostReference.ProcurementStockIn stock)
                ||stock.stockInItemId()==null||!stock.stockInItemId().equals(req.sourceItemId()))
            throw new IllegalArgumentException("a reserved movement requires its exact procurement stock-in reference");
        return recordMovementInternal(reservedMovementId,req);
    }

    private UUID recordMovementInternal(UUID reservedMovementId,MovementRequest req){
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
        if (req.weight() != null && req.weight().signum() < 0) {
            throw new IllegalArgumentException("inventory movement weight must not be negative");
        }
        if (req.weight() == null && req.weightUnitId() != null) {
            throw new IllegalArgumentException(
                    "inventory movement weight unit requires an actual weight");
        }
        // Re-entrant when the top-level document already batch-locked its keys;
        // mandatory as a safe fallback for future single-movement callers.
        inventoryLock.lock(new InventoryKey(req.goodsId(), req.colorId()));
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
            BigDecimal availableWeight = physical == null ? null : physical.getWeight();
            if (req.weight() != null
                    && availableWeight != null
                    && availableWeight.compareTo(req.weight()) < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "目标仓库存重量不足：当前 "
                                + availableWeight.stripTrailingZeros().toPlainString()
                                + "，本次出库 "
                                + req.weight().stripTrailingZeros().toPlainString());
            }
            // A physical count loss records reality and must not be blocked by
            // an operational reservation policy. Every normal outbound path,
            // including returns, transfers and subcontract issues, may only
            // consume stock left after active reservations and safety stock.
            // KS-P1-1: 红冲/退货类 DIR_OUT 同样不守 movable（只守上方非负底线）——撤销入库/退供应商
            // 不应被他人预留卡死；非负底线已防真实负库存。
            if (req.movementType() != TYPE_CHECK_LOSS
                    && !REVERSAL_RETURN_TYPES.contains(req.movementType())) {
                boolean allocatedProductionIssue = false;
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
                BigDecimal movable = allocatedProductionIssue
                        ? balanceRepo.warehouseUnreservedBase(req.warehouseId(), req.goodsId(), req.colorId())
                        : balanceRepo.warehouseAvailableBase(req.warehouseId(), req.goodsId(), req.colorId());
                if (movable == null) movable = BigDecimal.ZERO;
                if (movable.compareTo(req.qty()) < 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            (allocatedProductionIssue ? "本仓剩余可领数量不足：当前 " : "可动用库存不足(已扣硬预留和安全库存)：当前 ")
                                    + movable.stripTrailingZeros().toPlainString()
                                    + "，本次出库 "
                                    + req.qty().stripTrailingZeros().toPlainString());
                }
            }
        }
        OffsetDateTime ts = req.transactionDate() != null ? req.transactionDate() : OffsetDateTime.now();

        StockMovement m = new StockMovement();
        if(reservedMovementId!=null){
            var prior=movementRepo.findById(reservedMovementId);
            if(prior.isPresent()){
                StockMovement old=prior.get();
                if(Objects.equals(old.getSourceDocType(),req.sourceDocType())&&Objects.equals(old.getSourceDocId(),req.sourceDocId())
                        &&Objects.equals(old.getSourceItemId(),req.sourceItemId())&&Objects.equals(old.getGoodsId(),req.goodsId())
                        &&Objects.equals(old.getColorId(),req.colorId())&&Objects.equals(old.getWarehouseId(),req.warehouseId())
                        &&old.getDirection()==req.direction()&&old.getMovementType()==req.movementType()&&old.getQty().compareTo(req.qty())==0
                        &&Objects.equals(old.getUnitId(),req.unitId())&&Objects.equals(old.getActualWeightUnitId(),req.weightUnitId())
                        &&sameDecimal(old.getUnitRate(),req.unitRate())&&sameDecimal(old.getWeight(),req.weight()))return old.getId();
                throw new ApiException(ErrorCode.CONFLICT,"预留库存流水UUID对应不同来源或数量，不能覆盖");
            }
            m.setId(reservedMovementId);
        }
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
        if(valued.replayed())return valued.movementId();
        m.setAmountLocal(valued.knownValueLocal());
        m.setWeight(req.weight());
        m.setActualWeightUnitId(req.weightUnitId());
        m.setRemark(req.remark());
        movementRepo.save(m);

        BigDecimal dir = BigDecimal.valueOf(req.direction());
        BigDecimal signedQty = req.qty().multiply(dir);
        BigDecimal signedAmt = valued.knownValueLocal().multiply(dir);
        // 重量：null=调用方不维护（旧调用方/无重量业务），upsert 内部保持原值；非 null 才按方向增减。
        BigDecimal signedWgt = req.weight() == null ? null : req.weight().multiply(dir);
        balanceRepo.upsertBalance(req.warehouseId(), req.goodsId(), req.colorId(),
                signedQty, signedAmt, signedWgt, ts);
        return m.getId();
    }

    private static boolean sameDecimal(BigDecimal a,BigDecimal b){return a==null?b==null:b!=null&&a.compareTo(b)==0;}
}
