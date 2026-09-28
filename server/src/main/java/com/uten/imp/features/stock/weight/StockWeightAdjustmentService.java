package com.uten.imp.features.stock.weight;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockBalanceRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * 只改重量、不动数量的库存调整(ADR-135 §3.4 / §3.5): 盘点定重(COUNT)、人工核重(MANUAL)、撤销盘点重量(REVERSAL)。
 *
 * <p>先拿本维度库存锁, 再读余额快照, 调整行与余额重量在同一条语句里写; 定过的重量是实称, 不再是估算。
 * 按重量计量的货品(精确货品)重量随数量自动算, 不接受单独定重。
 */
@Service
@RequiredArgsConstructor
public class StockWeightAdjustmentService {

    public static final String KIND_COUNT = StockWeightResolver.AdjustmentDraft.COUNT;
    public static final String KIND_MANUAL = StockWeightResolver.AdjustmentDraft.MANUAL;

    private static final String REVERSAL_REASON = "撤销盘点重量";
    private static final BigDecimal ZERO_KG = BigDecimal.ZERO.setScale(WeightMath.SCALE);

    private final InventoryMutationLock inventoryLock;
    private final StockBalanceRepository balances;
    private final StockWeightContextReader contexts;
    private final StockWeightAdjustmentRepository adjustments;

    /**
     * @param kind           COUNT(盘点/授权调整) 或 MANUAL(核重)
     * @param targetKg       定下的重量(千克, 大于等于 0)
     * @param expectedKg     提交人看到的当前重量(乐观核对), null = 看到的是未知
     * @param checkExpected  是否核对 expectedKg
     * @param idempotencyKey 可空; 同一键重放返回原调整行
     * @param actor          操作人(users.id), 可空时取事务绑定的操作人
     */
    public record SetWeightCommand(
            String kind,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            BigDecimal targetKg,
            BigDecimal expectedKg,
            boolean checkExpected,
            String sourceDocType,
            UUID sourceDocId,
            UUID sourceItemId,
            OffsetDateTime transactionDate,
            String reason,
            String idempotencyKey,
            UUID actor) {
    }

    /** 给一个库存维度定重量, 返回调整行 id。 */
    @Transactional
    public UUID setWeight(SetWeightCommand command) {
        if (command == null || command.warehouseId() == null || command.goodsId() == null) {
            throw new IllegalArgumentException("weight adjustment identity is incomplete");
        }
        if (!KIND_COUNT.equals(command.kind()) && !KIND_MANUAL.equals(command.kind())) {
            throw new IllegalArgumentException("weight adjustment kind must be COUNT or MANUAL");
        }
        if (command.targetKg() == null || command.targetKg().signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "重量不能为空或小于 0");
        }
        if (KIND_MANUAL.equals(command.kind()) && blankToNull(command.reason()) == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写核重原因");
        }
        inventoryLock.lock(new InventoryKey(command.goodsId(), command.colorId()));
        String key = command.idempotencyKey() == null || command.idempotencyKey().isBlank()
                ? null : command.idempotencyKey().trim();
        BigDecimal target = WeightMath.round4(command.targetKg());
        if (key != null) {
            var existing = adjustments.findByIdempotencyKey(key).orElse(null);
            if (existing != null) {
                if (!command.kind().equals(existing.kind())
                        || !command.warehouseId().equals(existing.warehouseId())
                        || !command.goodsId().equals(existing.goodsId())
                        || !Objects.equals(command.colorId(), existing.colorId())
                        || !WeightMath.sameKg(target, existing.weightAfter())) {
                    throw new ApiException(ErrorCode.CONFLICT, "同一次提交的重量内容不一致, 请刷新后重新提交");
                }
                return existing.id();
            }
        }
        if (contexts.goodsMassFactor(command.goodsId()) != null) {
            throw new ApiException(ErrorCode.CONFLICT, "按重量计量的货品重量随数量自动计算, 不用单独核重");
        }
        Snapshot snapshot = snapshot(command.warehouseId(), command.goodsId(), command.colorId());
        int qtySign = snapshot.qty().signum();
        if (qtySign < 0) {
            throw new ApiException(ErrorCode.CONFLICT, "库存数量是负数, 请先盘点数量再登记重量");
        }
        if (qtySign == 0 && KIND_MANUAL.equals(command.kind())) {
            throw new ApiException(ErrorCode.CONFLICT, "当前没有库存, 不用核重");
        }
        if (qtySign == 0 && target.signum() > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "库存数量为 0 时重量只能是 0");
        }
        if (qtySign > 0 && target.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "还有库存时重量必须大于 0");
        }
        if (command.checkExpected() && !WeightMath.sameKg(command.expectedKg(), snapshot.weight())) {
            throw new ApiException(ErrorCode.CONFLICT, "库存重量已变化, 请刷新后重试");
        }
        return adjustments.insertAndSetBalance(new StockWeightAdjustmentRepository.NewAdjustment(
                command.kind(), timestamp(command.transactionDate()),
                command.warehouseId(), command.goodsId(), command.colorId(),
                snapshot.weight(), target, null, null,
                command.sourceDocType(), command.sourceDocId(), command.sourceItemId(),
                blankToNull(command.reason()), command.actor(), key), false);
    }

    /**
     * 撤销某来源行上的盘点定重(盘点单红冲, §3.4): 在数量已按原流水镜像回去之后调用, 每条未撤销的定重补一行撤销,
     * 最新的先撤。返回补写的撤销行数。
     */
    @Transactional
    public int reverseSetWeight(String sourceDocType, UUID sourceDocId, UUID sourceItemId,
                                OffsetDateTime ts, UUID actor) {
        if (sourceDocType == null || sourceDocId == null) {
            throw new IllegalArgumentException("weight adjustment reversal requires its source document");
        }
        List<StockWeightAdjustmentRepository.OpenCount> counts =
                adjustments.openCounts(sourceDocType, sourceDocId, sourceItemId);
        if (counts.isEmpty()) return 0;
        inventoryLock.lockAll(counts.stream()
                .map(count -> new InventoryKey(count.goodsId(), count.colorId())).toList());
        OffsetDateTime at = timestamp(ts);
        for (StockWeightAdjustmentRepository.OpenCount count : counts) {
            Snapshot snapshot = snapshot(count.warehouseId(), count.goodsId(), count.colorId());
            StockWeightResolver.CountReversal reversal = StockWeightResolver.reverseCount(
                    snapshot.qty(), snapshot.weight(), snapshot.estimated(),
                    count.weightBefore(), count.weightAfter());
            adjustments.insertAndSetBalance(new StockWeightAdjustmentRepository.NewAdjustment(
                    StockWeightResolver.AdjustmentDraft.REVERSAL, at,
                    count.warehouseId(), count.goodsId(), count.colorId(),
                    snapshot.weight(), reversal.weightAfter(), null, count.id(),
                    sourceDocType, sourceDocId, sourceItemId, REVERSAL_REASON, actor, null),
                    reversal.estimatedAfter());
        }
        return counts.size();
    }

    /** 余额快照; 没有余额行按「0 数量 0 重量」。 */
    private Snapshot snapshot(UUID warehouseId, UUID goodsId, UUID colorId) {
        var rows = balances.readPhysicalSnapshot(warehouseId, goodsId, colorId);
        if (rows.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT, "库存维度存在重复余额, 请先核对");
        }
        if (rows.isEmpty()) return new Snapshot(BigDecimal.ZERO, ZERO_KG, false);
        var row = rows.getFirst();
        return new Snapshot(row.getQty() == null ? BigDecimal.ZERO : row.getQty(), row.getWeight(),
                Boolean.TRUE.equals(row.getWeightEstimated()));
    }

    private record Snapshot(BigDecimal qty, BigDecimal weight, boolean estimated) {
    }

    private static OffsetDateTime timestamp(OffsetDateTime value) {
        return value == null ? OffsetDateTime.now() : value;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
