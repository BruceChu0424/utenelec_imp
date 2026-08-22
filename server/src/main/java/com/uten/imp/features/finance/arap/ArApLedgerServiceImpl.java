package com.uten.imp.features.finance.arap;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.features.finance.payables.SupplierClosedPeriodGuard;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 应收应付台账 Service 实现（跨模块枢纽，钱流模块独家实现）。
 *
 * <p>销售/采购/委外模块审核 Service 在同一事务内注入本接口调 {@link #postArAp} 立应收/应付，
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
    private final ArApSourceRefRepository sourceRefRepo;
    private final TxSessionVars tx;
    private final GlPostingService glPosting;
    private final SupplierClosedPeriodGuard closedPeriodGuard;

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
        LocalDate billDate = req.billDate() != null ? req.billDate() : BusinessTime.today();
        if ("AP".equals(req.direction())) {
            closedPeriodGuard.requireOpen(
                    req.supplierId(),req.currencyId(),billDate,"供应商应付立账");
        }
        glPosting.lockAutoProjectionPeriod(billDate);
        if (!repo.findBySourceForUpdate(req.sourceDocId(), req.sourceDocType()).isEmpty()) {
            throw new IllegalStateException(
                    "source document is already posted: "
                            + req.sourceDocType() + "/" + req.sourceDocId());
        }
        BigDecimal originalLocal = nz(req.amountOriginalLocal());
        BigDecimal original = req.amountOriginal() != null
                ? req.amountOriginal()
                : originalLocal;
        validateSourceRefs(req.sourceRefs(), original, originalLocal);

        ArApLedger l = new ArApLedger();
        l.setDirection(req.direction());
        l.setBusinessType(businessType(req.direction(), req.sourceDocType()));
        l.setOpenItemKind(openItemKind(req.direction(), req.sourceDocType(), originalLocal));
        l.setSourceDocType(req.sourceDocType());
        l.setSourceDocId(req.sourceDocId());
        l.setSourceDocNo(req.sourceDocNo());
        l.setBillNo(req.sourceDocNo() != null ? req.sourceDocNo() : "DIRECT-" + System.nanoTime());
        l.setBillDate(billDate);
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
        l.setAmountOriginal(original);
        l.setAmountOriginalLocal(originalLocal);
        l.setAmountSettled(BigDecimal.ZERO);
        l.setAmountReceivedOriginal(BigDecimal.ZERO);
        l.setAmountReceivedLocal(BigDecimal.ZERO);
        l.setAmountWriteOffOriginal(BigDecimal.ZERO);
        l.setAmountWriteOffLocal(BigDecimal.ZERO);
        l.setAmountOffsetOriginal(BigDecimal.ZERO);
        l.setAmountOffsetLocal(BigDecimal.ZERO);
        l.setAmountBalanceOriginal(original);
        l.setAmountBalance(originalLocal);
        boolean settled = originalLocal.signum() == 0;
        l.setSettled(settled);
        if (settled) {
            l.setSettledDate(l.getBillDate());
        }
        l.setStatus((short) 1);
        l.setLegacyBstyle(req.legacyBstyle());
        l.setDueDate(req.dueDate());
        l.setSettlementStyleLegacy(req.settlementStyleLegacy());
        l.setSettlementTypeId(req.settlementMethodId());
        l.setRemark(req.remark());
        repo.save(l);
        // sourceRefs 只保存 ledgerId（不建 JPA 双向关联）。项目开启了
        // hibernate.order_inserts，因此先 flush 父行，避免批处理重排时触发 FK。
        repo.flush();
        saveSourceRefs(l, req.sourceRefs());
    }

    /**
     * 反立帐（红冲 1→-1）。若该单已有核销（amount_settled&lt;&gt;0），抛
     * {@link IllegalStateException}("此单已经存在收/付款，请先反审")，阻止红冲（对齐老库 RAISERROR 文案）。
     *
     * <p>立账行保留为已红冲审计事实（status=-1 + soft delete）。V332 的往来抵销事件
     * 使用 FK RESTRICT 长期引用 source/target ledger，所以禁止物理删除。来源必须且只能命中一条
     * 有效立账；缺失、重复或已有付款/抵销均 fail closed。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseArAp(java.util.UUID sourceDocId, String sourceDocType) {
        tx.bind();
        if (sourceDocId == null || sourceDocType == null) {
            throw new IllegalArgumentException("reverseArAp: sourceDocId/sourceDocType required");
        }
        List<ArApLedger> snapshot = repo.findBySourceDocIdAndSourceDocTypeAndDeletedFalse(
                sourceDocId, sourceDocType);
        if (snapshot.size() != 1) {
            throw new IllegalStateException(
                    "source posting is missing or duplicated: "
                            + sourceDocType + "/" + sourceDocId);
        }
        ArApLedger sourceLedger=snapshot.getFirst();
        if("AP".equals(sourceLedger.getDirection())){
            closedPeriodGuard.requireOpen(sourceLedger.getSupplierId(),
                    sourceLedger.getCurrencyId(),BusinessTime.today(),"供应商应付反立账");
        }
        glPosting.lockAutoProjectionPeriod(sourceLedger.getBillDate());
        List<ArApLedger> rows = repo.findBySourceForUpdate(sourceDocId, sourceDocType);
        if (rows.size() != 1) {
            throw new IllegalStateException(
                    "source posting is missing or duplicated: "
                            + sourceDocType + "/" + sourceDocId);
        }
        for (ArApLedger l : rows) {
            BigDecimal settled = nz(l.getAmountSettled());
            BigDecimal offsetOriginal = nz(l.getAmountOffsetOriginal());
            BigDecimal offsetLocal = nz(l.getAmountOffsetLocal());
            if (settled.signum() != 0
                    || offsetOriginal.signum() != 0
                    || offsetLocal.signum() != 0) {
                throw new IllegalStateException("此单已经存在收/付款或抵销，请先反向处理");
            }
        }
        ArApLedger ledger = rows.getFirst();
        glPosting.removeAutoProjection(
                projectionSourceType(ledger.getDirection(),sourceDocType),
                sourceDocType,
                sourceDocId,
                ledger.getBillNo(),
                ledger.getBillDate());
        OffsetDateTime reversedAt = OffsetDateTime.now();
        for (ArApLedger row : rows) {
            row.setStatus((short) -1);
            row.setDeleted(true);
            row.setDeletedAt(reversedAt);
        }
        repo.saveAll(rows);
    }

    private static String projectionSourceType(String direction,String sourceDocType) {
        return switch (direction) {
            case "AR" -> "AR_POST";
            case "AP" -> "SUBCONTRACT_LOSS_OFFSET".equals(sourceDocType)
                    ? "SUPPLIER_CLAIM_LEDGER" : "AP_POST";
            default -> throw new IllegalStateException(
                    "unsupported AR/AP projection direction: " + direction);
        };
    }

    private static String businessType(String direction, String sourceDocType) {
        if ("AR".equals(direction)) return "SALES";
        return switch (sourceDocType) {
            case "PURCHASE_RECEIPT", "PURCHASE_RETURN" -> "PURCHASE";
            case "SUBCONTRACT_RECEIPT", "SUBCONTRACT_RETURN", "SUBCONTRACT_WASTE",
                    "SUBCONTRACT_LOSS_OFFSET" -> "SUBCONTRACT";
            default -> "DIRECT";
        };
    }

    private static String openItemKind(
            String direction, String sourceDocType, BigDecimal originalLocal) {
        if ("AR".equals(direction)) {
            return "DIRECT_RECEIPT".equals(sourceDocType)
                    ? "CUSTOMER_PREPAYMENT" : "RECEIVABLE";
        }
        if ("DIRECT_PAYMENT".equals(sourceDocType)) return "PREPAYMENT";
        if ("SUBCONTRACT_WASTE".equals(sourceDocType)
                || "SUBCONTRACT_LOSS_OFFSET".equals(sourceDocType)) {
            return "CLAIM_CREDIT";
        }
        return originalLocal.signum() < 0 ? "CREDIT" : "PAYABLE";
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }

    private static void validateSourceRefs(
            List<SourceRef> refs, BigDecimal amountOriginal, BigDecimal amountLocal) {
        if (refs == null || refs.isEmpty()) {
            return;
        }
        Set<String> sourceKeys = new HashSet<>();
        BigDecimal sourceOriginal = BigDecimal.ZERO;
        BigDecimal sourceLocal = BigDecimal.ZERO;
        for (SourceRef ref : refs) {
            if (ref == null || ref.sourceId() == null || ref.sourceType() == null
                    || ref.sourceType().isBlank() || ref.sourceNo() == null
                    || ref.sourceNo().isBlank()) {
                throw new IllegalArgumentException("postArAp: source ref identity is required");
            }
            if (!ArApSourceRef.SALES_ORDER.equals(ref.sourceType())) {
                throw new IllegalArgumentException(
                        "postArAp: unsupported source ref type " + ref.sourceType());
            }
            if (!sourceKeys.add(ref.sourceType() + "/" + ref.sourceId())) {
                throw new IllegalArgumentException(
                        "postArAp: duplicated source ref " + ref.sourceType() + "/" + ref.sourceId());
            }
            sourceOriginal = sourceOriginal.add(nz(ref.amountOriginal()));
            sourceLocal = sourceLocal.add(nz(ref.amountLocal()));
        }
        if (sourceOriginal.compareTo(amountOriginal) != 0
                || sourceLocal.compareTo(amountLocal) != 0) {
            throw new IllegalArgumentException(
                    "postArAp: source ref amounts must equal posting amounts");
        }
    }

    private void saveSourceRefs(ArApLedger ledger, List<SourceRef> refs) {
        if (refs == null || refs.isEmpty()) {
            return;
        }
        List<ArApSourceRef> rows = new java.util.ArrayList<>(refs.size());
        for (int index = 0; index < refs.size(); index++) {
            SourceRef ref = refs.get(index);
            ArApSourceRef row = new ArApSourceRef();
            row.setLedgerId(ledger.getId());
            row.setSourceType(ref.sourceType());
            row.setSourceId(ref.sourceId());
            row.setSourceNo(ref.sourceNo().trim());
            row.setSourceSequence(index + 1);
            row.setAmountOriginal(nz(ref.amountOriginal()));
            row.setAmountLocal(nz(ref.amountLocal()));
            rows.add(row);
        }
        sourceRefRepo.saveAll(rows);
    }
}
