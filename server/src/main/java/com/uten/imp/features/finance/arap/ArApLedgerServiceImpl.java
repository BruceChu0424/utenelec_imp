package com.uten.imp.features.finance.arap;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

/**
 * 应收应付台账 Service 实现（跨模块枢纽，钱流模块独家实现）。
 *
 * <p>取代老库触发器立帐（S_Out→TRI_SOStockItem / P_In→TRI_PIStockItem / E_In→立应付）。
 * 销售/采购/委外模块审核 Service 在同一事务内注入本接口调 {@link #postArAp} 立应收/应付，
 * 红冲时调 {@link #reverseArAp}。事务策略：方法标注 {@link Propagation#MANDATORY}——
 * 必须由调用方（销售/采购/委外审核）的事务包裹，单线程独立调用即报错（防误用）。
 *
 * <p>核销（settleReceipt/settlePayment）的累加逻辑由 {@code FinanceReceiptService} /
 * {@code FinancePaymentService} 自管（加载实体 → 改 amountSettled/amountBalance → save 回写 +
 * 自动结清维护），本类只负责"立帐 / 反立帐"两端，接口与契约 §四严格对齐。
 *
 * <p>详见 docs/数据迁移/28-Java后端契约.md §四、27-DDL一致性契约.md §四。
 */
@Service
@RequiredArgsConstructor
public class ArApLedgerServiceImpl implements ArApLedgerService {

    private final ArApLedgerRepository repo;
    private final TxSessionVars tx;

    /**
     * 立应收(AR)/应付(AP)。审核 0→1 同事务调；调用方随后置 ar_posted=true（销售/委外侧）。
     *
     * <p>语义：
     * <ul>
     *   <li>direction="AR" → client_id 落地，supplier_id 置 null；direction="AP" 反之。</li>
     *   <li>{@code amountOriginalLocal} 退货为负（红字立帐，与正Red反转）。</li>
     *   <li>{@code amountBalance = amountOriginalLocal}（初始未核销），{@code amountSettled=0}。</li>
     *   <li>{@code isSettled = (amountBalance == 0)}（兼容 0 元立帐立刻结清）。</li>
     *   <li>{@code bill_no = source_doc_no}（实体注释：migration = source_doc_no）。</li>
     *   <li>{@code status = 1}（跨模块立帐即时生效，非草稿）。</li>
     * </ul>
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void postArAp(ArApPostingRequest req) {
        tx.bind();
        if (req == null) {
            throw new IllegalArgumentException("postArAp: req is null");
        }
        if (req.direction() == null || (!req.direction().equals("AR") && !req.direction().equals("AP"))) {
            throw new IllegalArgumentException("postArAp: direction must be AR or AP, got " + req.direction());
        }
        if (req.sourceDocId() == null || req.sourceDocType() == null
                || req.sourceDocType().isBlank()) {
            throw new IllegalArgumentException(
                    "postArAp: sourceDocId/sourceDocType required");
        }
        if ("AR".equals(req.direction()) && req.clientId() == null) {
            throw new IllegalArgumentException("postArAp: AR requires clientId");
        }
        if ("AP".equals(req.direction()) && req.supplierId() == null) {
            throw new IllegalArgumentException("postArAp: AP requires supplierId");
        }
        BigDecimal exchangeRate = req.exchangeRate() == null
                ? BigDecimal.ONE
                : req.exchangeRate();
        if (exchangeRate.signum() <= 0) {
            throw new IllegalArgumentException("postArAp: exchangeRate must be positive");
        }
        if (!repo.findBySourceForUpdate(req.sourceDocId(), req.sourceDocType()).isEmpty()) {
            throw new IllegalStateException(
                    "source document is already posted: "
                            + req.sourceDocType() + "/" + req.sourceDocId());
        }
        BigDecimal originalLocal = nz(req.amountOriginalLocal());

        ArApLedger l = new ArApLedger();
        l.setDirection(req.direction());
        l.setSourceDocType(req.sourceDocType());
        l.setSourceDocId(req.sourceDocId());
        l.setSourceDocNo(req.sourceDocNo());
        l.setBillNo(req.sourceDocNo() != null ? req.sourceDocNo() : "DIRECT-" + System.nanoTime());
        l.setBillDate(req.billDate() != null ? req.billDate() : BusinessTime.today());
        if ("AR".equals(req.direction())) {
            l.setClientId(req.clientId());
            l.setSupplierId(null);
        } else {
            l.setSupplierId(req.supplierId());
            l.setClientId(null);
        }
        l.setCurrencyId(req.currencyId());
        l.setExchangeRate(exchangeRate);
        // 多币种：调用方传原币额 (amountOriginal) 则落原币；未传则回退到本币（单币种兼容）。
        // 不用 exchangeRate 反推（避免精度/口径漂移）；exchangeRate 仅持久化备查。
        l.setAmountOriginal(req.amountOriginal() != null ? req.amountOriginal() : originalLocal);
        l.setAmountOriginalLocal(originalLocal);
        l.setAmountSettled(BigDecimal.ZERO);
        l.setAmountBalance(originalLocal);
        boolean settled = originalLocal.signum() == 0;
        l.setSettled(settled);
        if (settled) {
            l.setSettledDate(l.getBillDate());
        }
        l.setStatus((short) 1);
        l.setLegacyBstyle(req.legacyBstyle());
        l.setRemark(req.remark());
        repo.save(l);
    }

    /**
     * 反立帐（红冲 1→-1）。若该单已有核销（amount_settled&lt;&gt;0），抛
     * {@link IllegalStateException}("此单已经存在收/付款，请先反审")，阻止红冲（对齐老库 RAISERROR 文案）。
     *
     * <p>物理 DELETE（非软删）—— 立帐行是审核派生数据，红冲后不应保留污染报表。
     * 来源必须且只能命中一条有效立帐；缺失或历史重复均 fail closed，避免业务单已红冲但
     * 财务派生数据未被完整撤销。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseArAp(java.util.UUID sourceDocId, String sourceDocType) {
        tx.bind();
        if (sourceDocId == null || sourceDocType == null) {
            throw new IllegalArgumentException("reverseArAp: sourceDocId/sourceDocType required");
        }
        List<ArApLedger> rows = repo.findBySourceForUpdate(sourceDocId, sourceDocType);
        if (rows.size() != 1) {
            throw new IllegalStateException(
                    "source posting is missing or duplicated: "
                            + sourceDocType + "/" + sourceDocId);
        }
        for (ArApLedger l : rows) {
            BigDecimal settled = nz(l.getAmountSettled());
            if (settled.signum() != 0) {
                throw new IllegalStateException("此单已经存在收/付款，请先反审");
            }
        }
        repo.deleteAll(rows);
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
