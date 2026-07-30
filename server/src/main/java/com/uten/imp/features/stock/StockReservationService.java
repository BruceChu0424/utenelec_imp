package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 库存软预留服务（V90，业务链核心）。
 *
 * <p>只做通用原语，不感知上游单据类型（跨模块联动由各业务 Service 编排，契约 §一）：
 * <ul>
 *   <li>{@link #globalAvailableBase} — 全局可用量查询（下单校验口径）</li>
 *   <li>{@link #reserve} — 建一笔预留（默认全局预留 warehouse=null）</li>
 *   <li>{@link #releaseByOrderItems} — 对称释放（反审/取消/驳回），已消耗的不许释放</li>
 * </ul>
 *
 * <p>幂等与并发：调用方必须在单据审核状态机内、持有单据行锁（PESSIMISTIC_WRITE）时调用；
 * 校验可用量与建行在同一事务，关闭超卖窗口。
 */
@Service
@RequiredArgsConstructor
public class StockReservationService {

    private final StockReservationRepository reservationRepo;
    private final TxSessionVars tx;
    private final EntityManager em;

    /** 全局可用量（基本单位）：全仓账面 − 全部生效预留。 */
    @Transactional(readOnly = true)
    public BigDecimal globalAvailableBase(UUID goodsId, UUID colorId) {
        BigDecimal v = reservationRepo.globalAvailableBase(goodsId, colorId);
        return v == null ? BigDecimal.ZERO : v;
    }

    /**
     * 建一笔全局预留（基本单位）。
     *
     * @return 实际建行量（与 takeBase 一致；调用方已按可用量截断，这里不再二次校验）
     */
    @Transactional
    public StockReservation reserve(UUID orderItemId, UUID goodsId, UUID colorId,
                                    BigDecimal takeBase, short source,
                                    String sourceDocType, UUID sourceDocId) {
        return reserve(orderItemId, goodsId, colorId, null, takeBase, source, sourceDocType, sourceDocId);
    }

    /** 建一笔预留（可指定仓库；null=全局预留，出货开单选定仓库后改绑）。 */
    @Transactional
    public StockReservation reserve(UUID orderItemId, UUID goodsId, UUID colorId, UUID warehouseId,
                                    BigDecimal takeBase, short source,
                                    String sourceDocType, UUID sourceDocId) {
        tx.bind();
        if (takeBase == null || takeBase.signum() <= 0) {
            throw new ApiException(ErrorCode.BUSINESS, "预留数量必须大于 0");
        }
        StockReservation r = new StockReservation();
        r.setOrderItemId(orderItemId);
        r.setGoodsId(goodsId);
        r.setColorId(colorId);
        r.setWarehouseId(warehouseId);
        r.setQty(takeBase);
        r.setSource(source);
        r.setSourceDocType(sourceDocType);
        r.setSourceDocId(sourceDocId);
        return reservationRepo.save(r);
    }

    /**
     * 部分释放：出货驳回时按出货量释放订单行预留（FIFO，行锁）。
     *
     * <p>只释放生效部分（已消耗=已发货不在驳回范围，草稿单不可能有消耗）。
     * 生效总量不足时释放现有全部并返回实释量（调用方按行单位口径已换算）。
     *
     * @return 实际释放量（基本单位）
     */
    @Transactional
    public BigDecimal releaseForOrderItem(UUID orderItemId, BigDecimal qtyBase) {
        tx.bind();
        if (qtyBase == null || qtyBase.signum() <= 0) return BigDecimal.ZERO;
        @SuppressWarnings("unchecked")
        List<StockReservation> rs = em.createNativeQuery(
                        "SELECT * FROM stock_reservations"
                                + " WHERE order_item_id = :oid AND is_deleted = FALSE AND status = 0"
                                + " ORDER BY created_at FOR UPDATE", StockReservation.class)
                .setParameter("oid", orderItemId)
                .getResultList();
        BigDecimal remaining = qtyBase;
        for (StockReservation r : rs) {
            if (remaining.signum() <= 0) break;
            BigDecimal eff = r.effectiveQty();
            if (eff.signum() <= 0) continue;
            BigDecimal c = eff.min(remaining);
            r.setReleasedQty(r.getReleasedQty().add(c));
            if (r.effectiveQty().signum() == 0) {
                r.setStatus(StockReservation.STATUS_DONE);
            }
            reservationRepo.save(r);
            remaining = remaining.subtract(c);
        }
        return qtyBase.subtract(remaining);
    }

    /**
     * 按来源单据对称释放（如成品入库单红冲时，释放它当年补的预留）。
     *
     * <p>已消耗（货已发出）的预留拒绝释放——调用方业务校验的兜底防线。
     *
     * @return 释放总生效量（基本单位）
     */
    @Transactional
    public BigDecimal releaseBySourceDoc(String sourceDocType, UUID sourceDocId) {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<StockReservation> rs = em.createNativeQuery(
                        "SELECT * FROM stock_reservations"
                                + " WHERE source_doc_type = :t AND source_doc_id = :d"
                                + " AND is_deleted = FALSE AND status = 0 FOR UPDATE",
                        StockReservation.class)
                .setParameter("t", sourceDocType)
                .setParameter("d", sourceDocId)
                .getResultList();
        BigDecimal total = BigDecimal.ZERO;
        for (StockReservation r : rs) {
            if (r.getConsumedQty().signum() > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "该入库的货已有发货记录，不能红冲入库单");
            }
            BigDecimal eff = r.effectiveQty();
            if (eff.signum() > 0) {
                r.setReleasedQty(r.getReleasedQty().add(eff));
                total = total.add(eff);
            }
            r.setStatus(StockReservation.STATUS_DONE);
            reservationRepo.save(r);
        }
        return total;
    }

    /**
     * 出货消耗：按创建先后（FIFO）消耗订单行的生效预留，返回实际消耗量（基本单位）。
     *
     * <p>SELECT ... FOR UPDATE 锁住该行全部生效预留，防两张出货单并发双吃同一批预留。
     * 全局预留（warehouse=null）首次消耗时改绑出货仓。消耗尽的行置完结。
     * 不足时不抛错（订单行级 reserved_qty 校验已在业务 Service 前置兜底，
     * 基本单位换算尾差允许），返回实耗供调用方判断。
     */
    @Transactional
    public BigDecimal consumeForOrderItem(UUID orderItemId, UUID warehouseId, BigDecimal needBase) {
        tx.bind();
        if (needBase == null || needBase.signum() <= 0) return BigDecimal.ZERO;
        @SuppressWarnings("unchecked")
        List<StockReservation> rs = em.createNativeQuery(
                        "SELECT * FROM stock_reservations"
                                + " WHERE order_item_id = :oid AND is_deleted = FALSE AND status = 0"
                                + " ORDER BY created_at FOR UPDATE", StockReservation.class)
                .setParameter("oid", orderItemId)
                .getResultList();
        BigDecimal remaining = needBase;
        for (StockReservation r : rs) {
            if (remaining.signum() <= 0) break;
            BigDecimal eff = r.effectiveQty();
            if (eff.signum() <= 0) continue;
            BigDecimal c = eff.min(remaining);
            r.setConsumedQty(r.getConsumedQty().add(c));
            if (r.getWarehouseId() == null) {
                r.setWarehouseId(warehouseId); // 全局预留改绑出货仓
            }
            if (r.effectiveQty().signum() == 0) {
                r.setStatus(StockReservation.STATUS_DONE);
            }
            reservationRepo.save(r);
            remaining = remaining.subtract(c);
        }
        return needBase.subtract(remaining);
    }

    /**
     * 对称释放若干订单明细行的全部生效预留（反审/整单取消用）。
     *
     * <p>若存在已消耗（consumed_qty > 0）的预留，说明货已发出，拒绝释放——
     * 调用方应先以订单行 shipped_qty 做业务校验，此处为兜底防线。
     *
     * @return 释放总生效量（基本单位，审计/日志用）
     */
    @Transactional
    public BigDecimal releaseByOrderItems(List<UUID> orderItemIds) {
        tx.bind();
        if (orderItemIds == null || orderItemIds.isEmpty()) return BigDecimal.ZERO;
        List<StockReservation> rs = reservationRepo.findEffectiveByOrderItemIds(orderItemIds);
        // 消耗守卫按"净发货量"判定（修复部分消耗误拦）：Σ消耗 − Σ出货红冲重挂行 > 0 才真有货在外。
        // 出货红冲不抹原消耗行、而是货回库重新挂行（SALES_SHIPMENT_REVERSE）；
        // 发货已全部红冲净额为 0 时（调用方均已先校验 shipped_qty=0），历史消耗行不得再拦截红冲/取消。
        List<StockReservation> all = reservationRepo.findAllByOrderItemIds(orderItemIds);
        BigDecimal consumed = all.stream()
                .map(r -> r.getConsumedQty() == null ? BigDecimal.ZERO : r.getConsumedQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal rehung = all.stream()
                .filter(r -> "SALES_SHIPMENT_REVERSE".equals(r.getSourceDocType()))
                .map(r -> r.getQty() == null ? BigDecimal.ZERO : r.getQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (consumed.subtract(rehung).signum() > 0) {
            throw new ApiException(ErrorCode.BUSINESS, "订单已有发货记录，不能释放预留");
        }
        BigDecimal total = BigDecimal.ZERO;
        for (StockReservation r : rs) {
            BigDecimal eff = r.effectiveQty();
            if (eff.signum() > 0) {
                r.setReleasedQty(r.getReleasedQty().add(eff));
                total = total.add(eff);
            }
            r.setStatus(StockReservation.STATUS_DONE);
            reservationRepo.save(r);
        }
        return total;
    }
}
