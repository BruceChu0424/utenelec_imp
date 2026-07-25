package com.uten.imp.features.stock;

import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 库存联动服务：单据审核时在同一事务内「写流水 + upsert 余额」。
 *
 * <p>取代老库触发器直写 StockGoods（按月分列台账）。所有出入库单据（采购/销售/领料/盘点…）
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

    /** direction 字典。 */
    public static final short DIR_IN = 1;
    public static final short DIR_OUT = -1;

    /** 来源单据类型（source_doc_type）。 */
    public static final String SRC_PURCHASE_RECEIPT = "PURCHASE_RECEIPT";
    public static final String SRC_PURCHASE_RETURN = "PURCHASE_RETURN";

    private final StockMovementRepository movementRepo;
    private final StockBalanceRepository balanceRepo;
    private final TxSessionVars tx;

    /** 出入库请求值对象。qty 为基本单位量（已乘 unit_rate）；amountLocal 为本币金额。 */
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
            String remark) {
    }

    /**
     * 记一笔出入库：流水 + 余额（同事务，调用方需 @Transactional）。
     *
     * @param req 方向已体现在 direction（+1/-1），qty/amountLocal 传正数
     */
    @Transactional
    public void recordMovement(MovementRequest req) {
        tx.bind();
        OffsetDateTime ts = req.transactionDate() != null ? req.transactionDate() : OffsetDateTime.now();

        StockMovement m = new StockMovement();
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
        m.setAmountLocal(req.amountLocal());
        m.setRemark(req.remark());
        movementRepo.save(m);

        BigDecimal dir = BigDecimal.valueOf(req.direction());
        BigDecimal signedQty = req.qty().multiply(dir);
        BigDecimal signedAmt = (req.amountLocal() == null ? BigDecimal.ZERO : req.amountLocal()).multiply(dir);
        balanceRepo.upsertBalance(req.warehouseId(), req.goodsId(), req.colorId(),
                signedQty, signedAmt, ts);
    }
}
