package com.uten.imp.features.finance.arap;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付台账服务（跨模块契约）。
 *
 * <p>取代老库触发器立帐（S_Out/P_In/E_In 审核→M_in/M_out）。销售/委外/采购单据审核
 * 在同一事务内调用 {@link #postArAp} 立应收/应付；红冲调 {@link #reverseArAp}。
 *
 * <p>实现：钱流模块（features/finance/）。调用方：销售 shipment/return、委外 receipt/return、
 * 采购 receipt/ret（增强）。接口自包含（void 返回、值对象入参），便于跨模块并行开发。
 *
 * <p>详见 docs/数据迁移/28-Java后端契约.md §四、27-DDL一致性契约.md §四（ar_ap_ledger 表）。
 */
public interface ArApLedgerService {

    /**
     * 立应收(AR)/应付(AP)。审核 0→1 同事务内调；调用方随后置 ar_posted=true。
     *
     * @param req direction="AR" 落 client_id，"AP" 落 supplier_id；amountOriginalLocal 退货为负（红字）。
     */
    void postArAp(ArApPostingRequest req);

    /**
     * 反立帐（红冲 1→-1）。若该单已有收款/付款核销（amount_settled&lt;&gt;0），
     * 抛 IllegalStateException("此单已经存在收/付款，请先反审")，阻止红冲（对齐老库 RAISERROR 文案）。
     */
    void reverseArAp(UUID sourceDocId, String sourceDocType);

    /**
     * 立帐请求值对象。
     *
     * <p>{@code amountOriginal}（原币原额，可空）为多币种场景新增：非空时落
     * {@code ar_ap_ledger.amount_original}（原币），{@code amountOriginalLocal}（本币，退货为负）落
     * {@code amount_original_local}；为 null 时回退到本币值（单币种兼容，历史调用方零改）。
     * {@code exchangeRate} 始终持久化，不做反推（避免精度/口径漂移；调用方为金额权威）。
     */
    record ArApPostingRequest(
            String direction,            // "AR" 应收 / "AP" 应付
            String sourceDocType,        // SALES_SHIPMENT / SALES_RETURN / SUBCONTRACT_RECEIPT / PURCHASE_RECEIPT ...
            UUID sourceDocId,
            String sourceDocNo,
            LocalDate billDate,
            UUID clientId,               // AR 落此（AP 传 null）
            UUID supplierId,             // AP 落此（AR 传 null）
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal amountOriginalLocal,  // 原始金额（本币），退货为负
            Short legacyBstyle,          // 老库 BStyle 溯源（3/18/20 AR，1/17/30/21 AP），可空
            String remark,
            BigDecimal amountOriginal) { // 原币原额（多币种），可空：null 回退到 amountOriginalLocal

        /** 旧 12 参签名（现调用方零改）：未传原币原额时回退到本币。 */
        public ArApPostingRequest(String direction, String sourceDocType, UUID sourceDocId, String sourceDocNo,
                                  LocalDate billDate, UUID clientId, UUID supplierId, UUID currencyId,
                                  BigDecimal exchangeRate, BigDecimal amountOriginalLocal,
                                  Short legacyBstyle, String remark) {
            this(direction, sourceDocType, sourceDocId, sourceDocNo, billDate, clientId, supplierId,
                 currencyId, exchangeRate, amountOriginalLocal, legacyBstyle, remark, null);
        }
    }
}
