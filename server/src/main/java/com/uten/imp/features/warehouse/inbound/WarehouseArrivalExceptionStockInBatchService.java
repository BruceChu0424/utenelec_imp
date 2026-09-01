package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionStockInItemResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionStockInReceiptGroup;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * All-or-nothing coordinator for finance-approved arrival-exception receipt
 * submission. One selected exception may identify a receipt with multiple
 * adjusted lines, so execution is grouped by order type and receipt UUID and
 * each receipt is approved exactly once.
 */
@Service
@RequiredArgsConstructor
public class WarehouseArrivalExceptionStockInBatchService {

    private static final String COMPLETED = "COMPLETED";
    private static final String RECEIPT_ADJUSTED = "RECEIPT_ADJUSTED";
    private static final String RECEIPT_POSTED = "RECEIPT_POSTED";
    private static final String CLOSED = "CLOSED";

    private static final Comparator<WarehouseArrivalExceptionStockInBatchRepository.LockedException>
            LOCKED_ORDER = Comparator
            .comparing(
                    WarehouseArrivalExceptionStockInBatchRepository.LockedException::orderType,
                    Comparator.nullsLast(String::compareTo))
            .thenComparing(
                    item -> item.receiptId() == null ? null : item.receiptId().toString(),
                    Comparator.nullsLast(String::compareTo))
            .thenComparing(item -> item.exceptionId().toString());

    private final WarehouseArrivalExceptionStockInBatchRepository batches;
    private final ProcurementArrivalControlService arrivalControl;
    private final PurchaseReceiptService purchaseReceipts;
    private final SubcontractReceiptService subcontractReceipts;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ObjectMapper objectMapper;

    @Transactional
    @PreAuthorize("hasAuthority('warehouse_inbound:stock_in')")
    public WarehouseArrivalExceptionBatchStockInResult stockInBatch(
            WarehouseArrivalExceptionBatchStockInRequest request) {
        tx.bind();
        NormalizedRequest normalized = normalize(request);
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();

        batches.lockCommand(actorUserId, normalized.idempotencyKey());
        WarehouseArrivalExceptionStockInBatchRepository.ExistingCommand existing =
                batches.findExisting(actorUserId, normalized.idempotencyKey());
        if (existing != null) {
            if (!Objects.equals(existing.requestHash(), normalized.requestHash())) {
                throw conflict("该批量入账幂等键已用于不同任务集合，请更换幂等键后重试");
            }
            if (!COMPLETED.equals(existing.status()) || existing.resultJson() == null) {
                throw conflict("该批量入账命令尚未形成完整结果，请稍后重试");
            }
            return replay(existing.resultJson());
        }

        UUID batchId = UUID.randomUUID();
        batches.insertPending(
                batchId,
                actorUserId,
                actorEmployeeId,
                normalized.idempotencyKey(),
                normalized.requestHash(),
                normalized.items().size());

        Map<UUID, Long> expectedVersions = new HashMap<>();
        for (NormalizedItem item : normalized.items()) {
            expectedVersions.put(item.exceptionId(), item.expectedVersion());
        }
        List<WarehouseArrivalExceptionStockInBatchRepository.LockedException> locked =
                new ArrayList<>(batches.lockExceptions(
                        normalized.items().stream().map(NormalizedItem::exceptionId).toList()));
        if (locked.size() != normalized.items().size()) {
            throw conflict("部分到货异常任务不存在或已变化，请刷新后重新选择");
        }
        locked.sort(LOCKED_ORDER);
        validateLocked(locked, expectedVersions);

        LinkedHashMap<ReceiptKey,
                List<WarehouseArrivalExceptionStockInBatchRepository.LockedException>> grouped =
                new LinkedHashMap<>();
        for (WarehouseArrivalExceptionStockInBatchRepository.LockedException item : locked) {
            grouped.computeIfAbsent(
                    new ReceiptKey(item.orderType(), item.receiptId()),
                    ignored -> new ArrayList<>()).add(item);
        }

        List<WarehouseArrivalExceptionStockInReceiptGroup> receiptGroups =
                new ArrayList<>(grouped.size());
        List<WarehouseArrivalExceptionStockInBatchRepository.PersistedItem> persisted =
                new ArrayList<>(locked.size());
        for (Map.Entry<ReceiptKey,
                List<WarehouseArrivalExceptionStockInBatchRepository.LockedException>>
                entry : grouped.entrySet()) {
            ReceiptKey key = entry.getKey();
            List<WarehouseArrivalExceptionStockInBatchRepository.LockedException> group =
                    entry.getValue();
            String receiptBillNo = requireSingleReceiptBillNo(group);
            UUID representativeExceptionId = group.getFirst().exceptionId();

            arrivalControl.stockInWithDecisionSession(
                    representativeExceptionId,
                    target -> approveReceipt(key, target));

            List<WarehouseArrivalExceptionStockInItemResult> itemResults =
                    new ArrayList<>(group.size());
            for (WarehouseArrivalExceptionStockInBatchRepository.LockedException item : group) {
                ArrivalExceptionTask result =
                        arrivalControl.warehouseExceptionDetail(item.exceptionId());
                if (!Set.of(RECEIPT_POSTED, CLOSED).contains(result.status())) {
                    throw conflict("到货异常入账后状态未收敛，请刷新并联系管理员");
                }
                itemResults.add(new WarehouseArrivalExceptionStockInItemResult(
                        item.exceptionId(),
                        expectedVersions.get(item.exceptionId()),
                        result.status(),
                        result.version()));
                persisted.add(new WarehouseArrivalExceptionStockInBatchRepository.PersistedItem(
                        item.exceptionId(),
                        expectedVersions.get(item.exceptionId()),
                        item.orderType(),
                        item.receiptId(),
                        receiptBillNo,
                        result.status(),
                        result.version()));
            }
            receiptGroups.add(new WarehouseArrivalExceptionStockInReceiptGroup(
                    key.orderType(),
                    key.receiptId(),
                    receiptBillNo,
                    true,
                    itemResults));
        }

        WarehouseArrivalExceptionBatchStockInResult result =
                new WarehouseArrivalExceptionBatchStockInResult(
                        batchId,
                        false,
                        true,
                        normalized.items().size(),
                        receiptGroups);
        batches.insertItems(batchId, persisted);
        batches.complete(batchId, receiptGroups.size(), json(result));
        return result;
    }

    private void approveReceipt(
            ReceiptKey expected,
            ProcurementArrivalControlService.StockTarget actual) {
        if (!Objects.equals(expected.orderType(), actual.orderType())
                || !Objects.equals(expected.receiptId(), actual.receiptId())) {
            throw conflict("到货异常与收货单分组不一致，请刷新后重试");
        }
        if (ProcurementArrivalControlPort.PURCHASE.equals(expected.orderType())) {
            purchaseReceipts.approveFromWarehouseDecision(expected.receiptId());
            return;
        }
        if (ProcurementArrivalControlPort.SUBCONTRACT.equals(expected.orderType())) {
            subcontractReceipts.approveFromWarehouseDecision(expected.receiptId());
            return;
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "到货异常订货类型无效");
    }

    private static void validateLocked(
            List<WarehouseArrivalExceptionStockInBatchRepository.LockedException> locked,
            Map<UUID, Long> expectedVersions) {
        Set<UUID> seen = new HashSet<>();
        for (WarehouseArrivalExceptionStockInBatchRepository.LockedException item : locked) {
            Long expectedVersion = expectedVersions.get(item.exceptionId());
            if (expectedVersion == null || !seen.add(item.exceptionId())) {
                throw conflict("批量到货异常任务身份不一致，请刷新后重试");
            }
            if (item.version() != expectedVersion) {
                throw conflict("到货异常任务版本已变化，请刷新后重新确认整批任务");
            }
            if (!RECEIPT_ADJUSTED.equals(item.status())
                    || item.acceptedQty() == null
                    || item.acceptedQty().signum() <= 0) {
                throw conflict("所选到货异常已不满足财务批准量入账条件，请刷新后重试");
            }
            if (!Set.of(
                    ProcurementArrivalControlPort.PURCHASE,
                    ProcurementArrivalControlPort.SUBCONTRACT)
                    .contains(item.orderType())
                    || item.receiptId() == null
                    || item.receiptBillNo() == null
                    || item.receiptBillNo().isBlank()) {
                throw conflict("到货异常缺少有效收货单身份，请刷新后重试");
            }
        }
    }

    private static String requireSingleReceiptBillNo(
            List<WarehouseArrivalExceptionStockInBatchRepository.LockedException> group) {
        String billNo = group.getFirst().receiptBillNo().strip();
        boolean consistent = group.stream().allMatch(
                item -> item.receiptBillNo() != null
                        && billNo.equals(item.receiptBillNo().strip()));
        if (!consistent) {
            throw conflict("同一收货单的到货异常编号快照不一致，请联系管理员");
        }
        return billNo;
    }

    static NormalizedRequest normalize(
            WarehouseArrivalExceptionBatchStockInRequest request) {
        if (request == null || request.idempotencyKey() == null
                || request.items() == null || request.items().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量入账请求不能为空");
        }
        String key = request.idempotencyKey().strip();
        if (key.length() < 8 || key.length() > 128
                || !key.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量入账幂等键格式无效");
        }
        if (request.items().size() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多处理 100 条到货异常");
        }
        Set<UUID> ids = new HashSet<>();
        List<NormalizedItem> items = new ArrayList<>(request.items().size());
        for (WarehouseArrivalExceptionBatchStockInItem item : request.items()) {
            if (item == null || item.exceptionId() == null
                    || item.expectedVersion() == null
                    || item.expectedVersion() < 1) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批量入账任务身份或版本无效");
            }
            if (!ids.add(item.exceptionId())) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批量入账不能重复选择同一到货异常");
            }
            items.add(new NormalizedItem(
                    item.exceptionId(), item.expectedVersion()));
        }
        items.sort(Comparator.comparing(item -> item.exceptionId().toString()));
        List<String> hashParts = new ArrayList<>();
        hashParts.add("WAREHOUSE-ARRIVAL-EXCEPTION-STOCK-IN-V1");
        for (NormalizedItem item : items) {
            hashParts.add(item.exceptionId() + "|" + item.expectedVersion());
        }
        return new NormalizedRequest(
                key,
                CanonicalFingerprint.sha256(hashParts),
                List.copyOf(items));
    }

    static String requestHash(WarehouseArrivalExceptionBatchStockInRequest request) {
        return normalize(request).requestHash();
    }

    private WarehouseArrivalExceptionBatchStockInResult replay(String resultJson) {
        try {
            WarehouseArrivalExceptionBatchStockInResult stored =
                    objectMapper.readValue(
                            resultJson,
                            WarehouseArrivalExceptionBatchStockInResult.class);
            return new WarehouseArrivalExceptionBatchStockInResult(
                    stored.batchId(),
                    true,
                    stored.submittedForInspection(),
                    stored.processedExceptions(),
                    stored.receiptGroups());
        } catch (JsonProcessingException error) {
            throw new IllegalStateException(
                    "warehouse arrival exception batch replay snapshot is invalid",
                    error);
        }
    }

    private String json(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException(
                    "warehouse arrival exception batch result cannot be serialized",
                    error);
        }
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    record NormalizedRequest(
            String idempotencyKey,
            String requestHash,
            List<NormalizedItem> items) {
    }

    record NormalizedItem(UUID exceptionId, long expectedVersion) {
    }

    private record ReceiptKey(String orderType, UUID receiptId) {
    }
}
