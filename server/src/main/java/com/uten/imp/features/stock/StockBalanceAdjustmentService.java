package com.uten.imp.features.stock;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentResult;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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
 */
@Service
@RequiredArgsConstructor
public class StockBalanceAdjustmentService {

    private static final String REMARK_PREFIX = "[授权余额调整] ";

    private final StockBalanceRepository balanceRepo;
    private final StockService stockService;
    private final StockDocService stockDocService;
    private final TxSessionVars tx;

    @Transactional
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public StockBalanceAdjustmentResult adjust(StockBalanceAdjustmentRequest request) {
        tx.bind();
        requireValidRequest(request);

        InventoryKey key = new InventoryKey(request.getGoodsId(), request.getColorId());
        stockService.lockInventory(List.of(key));

        StockDocDetail existing = stockDocService
                .findAuthorizedBalanceAdjustment(request.getIdempotencyKey())
                .orElse(null);
        if (existing != null) {
            return replayExisting(existing, request);
        }

        BigDecimal currentQty = balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                        request.getWarehouseId(), request.getGoodsId(), request.getColorId())
                .map(StockBalance::getQty)
                .orElse(BigDecimal.ZERO);
        BigDecimal expectedQty = request.getExpectedQty();
        BigDecimal targetQty = request.getTargetQty();

        if (currentQty.compareTo(expectedQty) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "库存已发生变化：页面显示 "
                            + plain(expectedQty)
                            + "，当前实际 "
                            + plain(currentQty)
                            + "。请刷新后重新确认调整数量");
        }
        if (currentQty.compareTo(targetQty) == 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "调整后数量与当前库存相同，无需提交");
        }

        String reason = request.getReason().trim();
        String auditRemark = REMARK_PREFIX + reason;

        StockDocItemLine line = new StockDocItemLine();
        line.setLineNo(1);
        line.setGoodsId(request.getGoodsId());
        line.setColorId(request.getColorId());
        line.setQty(currentQty);
        line.setCountQty(targetQty);
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
                approved.getCreatedAt());
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
                existing.getCreatedAt());
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
