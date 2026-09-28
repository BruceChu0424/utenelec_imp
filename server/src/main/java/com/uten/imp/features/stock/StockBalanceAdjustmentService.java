package com.uten.imp.features.stock;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentResult;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.WeightInput;
import com.uten.imp.features.stock.weight.WeightMath;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;

/**
 * 高权限库存余额直接调整。
 *
 * <p>页面表现为把余额直接改成目标值；内部复用 CHECK 盘点单，立即生成并审核，
 * 因而修改前值、修改后值、差额、原因、操作者和库存流水都可追溯。
 *
 * <p>可选的目标重量(ADR-135 §3.4)落在盘点行的实盘重量上, 审核时记一行盘点定重(原因「授权调整」),
 * 不进单重学习; 数量不变而重量不同也可以提交。
 */
@Service
@RequiredArgsConstructor
public class StockBalanceAdjustmentService {

    private static final String REMARK_PREFIX = "[授权余额调整] ";

    private final StockBalanceRepository balanceRepo;
    private final StockService stockService;
    private final StockDocService stockDocService;
    private final TxSessionVars tx;
    private final FulfillmentMutationLocks mutationLocks;
    private final ProductionMutationFootprintPort mutationFootprints;

    /** 直接改余额为目标值：加锁后用 expectedQty 做乐观前置校验（页面值≠当前实际值即 409，防覆盖他人改动），命中幂等键则原样回放既有 CHECK 单，否则当场生成并审核一张 CHECK 盘点单（差额/原因/操作者皆可追溯）。 */
    @Transactional
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public StockBalanceAdjustmentResult adjust(StockBalanceAdjustmentRequest request) {
        tx.bind();
        requireValidRequest(request);

        // 锁序(履约预锁先于库存锁): 先拿本维度的来源前缀, 再拿库存锁; 随后建盘点单、审核里的预锁都落在这个前缀之内。
        // 先拿库存锁的话, 审核时再补前缀会被判成「已进入库存锁阶段」而整笔 409。
        mutationLocks.acquire(() -> mutationFootprints.forInventoryChange(
                List.of(new ProductionMutationFootprintPort.WarehouseDimension(
                        request.getWarehouseId(), request.getGoodsId(), request.getColorId())),
                List.of()));
        InventoryKey key = new InventoryKey(request.getGoodsId(), request.getColorId());
        stockService.lockInventory(List.of(key));

        StockDocDetail existing = stockDocService
                .findAuthorizedBalanceAdjustment(request.getIdempotencyKey())
                .orElse(null);
        if (existing != null) {
            return replayExisting(existing, request);
        }

        StockBalance balance = balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                        request.getWarehouseId(), request.getGoodsId(), request.getColorId())
                .orElse(null);
        BigDecimal currentQty = balance == null ? BigDecimal.ZERO : balance.getQty();
        BigDecimal currentWeight = balance == null ? null : balance.getWeight();
        BigDecimal expectedQty = request.getExpectedQty();
        BigDecimal targetQty = request.getTargetQty();
        BigDecimal targetWeight = targetWeight(request);

        if (currentQty.compareTo(expectedQty) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "库存已发生变化：页面显示 "
                            + plain(expectedQty)
                            + "，当前实际 "
                            + plain(currentQty)
                            + "。请刷新后重新确认调整数量");
        }
        if (currentQty.compareTo(targetQty) == 0
                && (targetWeight == null || WeightMath.sameKg(targetWeight, currentWeight))) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    targetWeight == null
                            ? "调整后数量与当前库存相同，无需提交"
                            : "调整后数量和重量都与当前库存相同，无需提交");
        }

        String reason = request.getReason().trim();
        String auditRemark = REMARK_PREFIX + reason;

        StockDocItemLine line = new StockDocItemLine();
        line.setLineNo(1);
        line.setGoodsId(request.getGoodsId());
        line.setColorId(request.getColorId());
        line.setQty(currentQty);
        line.setCountQty(targetQty);
        line.setCountWeight(targetWeight);
        line.setRemark(auditRemark);

        StockDocSaveRequest document = new StockDocSaveRequest();
        document.setDocType("CHECK");
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(request.getWarehouseId());
        document.setRemark(auditRemark);
        document.setItems(List.of(line));

        StockDocDetail draft = stockDocService.createAuthorizedBalanceAdjustment(
                document, request.getIdempotencyKey());
        StockDocDetail approved = stockDocService.approve(draft.getId());

        return new StockBalanceAdjustmentResult(
                approved.getId(),
                approved.getBillNo(),
                currentQty,
                targetQty,
                targetQty.subtract(currentQty),
                approved.getMakerId(),
                approved.getMakerName(),
                approved.getCreatedAt(),
                targetWeight);
    }

    private static StockBalanceAdjustmentResult replayExisting(
            StockDocDetail existing,
            StockBalanceAdjustmentRequest request) {
        if (existing.getItems() == null || existing.getItems().size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "该幂等键已有不完整的库存调整记录，请联系管理员");
        }
        var item = existing.getItems().getFirst();
        boolean sameRequest = request.getWarehouseId().equals(existing.getWarehouseId())
                && request.getGoodsId().equals(item.getGoodsId())
                && java.util.Objects.equals(request.getColorId(), item.getColorId())
                && sameNumber(request.getExpectedQty(), item.getQty())
                && sameNumber(request.getTargetQty(), item.getCountQty())
                && WeightMath.sameKg(targetWeight(request), item.getCountWeight())
                && (REMARK_PREFIX + request.getReason().trim()).equals(existing.getRemark());
        if (!sameRequest) {
            throw new ApiException(ErrorCode.CONFLICT, "该幂等键已用于另一笔库存调整，请重新提交");
        }
        return new StockBalanceAdjustmentResult(
                existing.getId(),
                existing.getBillNo(),
                item.getQty(),
                item.getCountQty(),
                item.getCountQty().subtract(item.getQty()),
                existing.getMakerId(),
                existing.getMakerName(),
                existing.getCreatedAt(),
                item.getCountWeight());
    }

    /**
     * 目标重量(千克, 空或 0 = 不改重量)。调整后数量为 0 时不能带重量(没有库存就没有重量)。
     */
    private static BigDecimal targetWeight(StockBalanceAdjustmentRequest request) {
        BigDecimal weight = WeightInput.kg(request.getTargetWeightKg(), "调整后重量");
        if (weight != null && request.getTargetQty().signum() == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "调整后数量为 0 时不能填写重量");
        }
        return weight;
    }

    private static boolean sameNumber(BigDecimal left, BigDecimal right) {
        return left != null && right != null && left.compareTo(right) == 0;
    }

    private static void requireValidRequest(StockBalanceAdjustmentRequest request) {
        if (request == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getWarehouseId() == null
                || request.getGoodsId() == null
                || request.getExpectedQty() == null
                || request.getTargetQty() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "库存调整参数不完整");
        }
        String idempotencyKey = request.getIdempotencyKey();
        if (idempotencyKey.length() < 8
                || idempotencyKey.length() > 128
                || !idempotencyKey.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "库存调整幂等键格式不正确");
        }
        if (request.getTargetQty().signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "调整后数量不能小于 0");
        }
        if (request.getReason() == null || request.getReason().trim().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "必须填写调整原因");
        }
        if (request.getReason().length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "调整原因不能超过 500 个字符");
        }
    }

    private static String plain(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
    }
}
