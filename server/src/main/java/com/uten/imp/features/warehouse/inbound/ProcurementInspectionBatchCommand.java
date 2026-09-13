package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.*;

/** Complete transport identity, independent of current inspection projections. */
record ProcurementInspectionBatchCommand(
        List<Line> lines, List<Event> events, Set<UUID> candidateEventIds,
        String requestHash, boolean allowLegacyPassReplay) {

    record Line(UUID inspectionItemId, BigDecimal expectedRemaining,
                BigDecimal pass, BigDecimal fail, String key) {}
    record Event(UUID id, UUID inspectionItemId, String action,
                 BigDecimal quantity, String reason) {}

    static ProcurementInspectionBatchCommand pass(String type, UUID receipt, BatchInspectionPassRequest request) {
        if (request == null || request.items() == null || request.items().isEmpty()) throw invalid("批量合格明细不能为空");
        if (request.items().size() > 100) throw invalid("一次最多合格放行 100 条明细");
        var lines = new ArrayList<Line>();
        var ids = new HashSet<UUID>();
        for (var item : request.items()) {
            if (item == null || item.inspectionItemId() == null) throw invalid("批量合格明细 ID 不能为空");
            if (!ids.add(item.inspectionItemId())) throw invalid("批量合格明细不能重复");
            BigDecimal quantity = normalizeQty(item.expectedRemainingBaseQty());
            lines.add(new Line(item.inspectionItemId(), quantity, quantity, BigDecimal.ZERO,
                    normalizeIdempotencyKey(item.idempotencyKey())));
        }
        return build(type, receipt, lines, normalizeDispositionReason("PASS", request.reason()), true);
    }

    static ProcurementInspectionBatchCommand decide(String type, UUID receipt, BatchInspectionDecideRequest request) {
        if (request == null || request.items() == null || request.items().isEmpty()) throw invalid("检验报告明细不能为空");
        if (request.items().size() > 100) throw invalid("一次最多提交 100 条明细");
        var lines = new ArrayList<Line>();
        var ids = new HashSet<UUID>();
        boolean hasFail = false;
        for (var item : request.items()) {
            if (item == null || item.inspectionItemId() == null) throw invalid("检验报告明细 ID 不能为空");
            if (!ids.add(item.inspectionItemId())) throw invalid("检验报告明细不能重复");
            BigDecimal remaining = normalizeQty(item.expectedRemainingBaseQty());
            BigDecimal pass = requireNonNegativeQty(item.passBaseQty(), "合格数量");
            BigDecimal fail = requireNonNegativeQty(item.failBaseQty(), "不合格数量");
            BigDecimal total = pass.add(fail);
            if (total.signum() <= 0) throw invalid("检验报告每行合格与不合格数量不能同时为 0");
            if (total.compareTo(remaining) > 0) throw new ApiException(ErrorCode.CONFLICT, "合格 + 不合格数量不能超过剩余待检数量 " + remaining.stripTrailingZeros().toPlainString());
            hasFail |= fail.signum() > 0;
            lines.add(new Line(item.inspectionItemId(), remaining, pass, fail, normalizeIdempotencyKey(item.idempotencyKey())));
        }
        return build(type, receipt, lines, normalizeDispositionReason(hasFail ? "FAIL" : "PASS", request.reason()), false);
    }

    private static ProcurementInspectionBatchCommand build(String type, UUID receipt, List<Line> lines,
                                                            String reason, boolean fullPass) {
        if ((!"PURCHASE".equals(type) && !"SUBCONTRACT".equals(type)) || receipt == null) throw invalid("收货单类型或 ID 无效");
        lines.sort(Comparator.comparing(line -> line.inspectionItemId().toString()));
        List<String> identity = new ArrayList<>(List.of(
                "operation:" + (fullPass ? "IQC-PASS-BATCH-V1" : "IQC-DECIDE-BATCH-V1"),
                "receiptType:" + type, "receiptId:" + receipt,
                reason == null ? "reason:null" : "reason:text:" + reason));
        var events = new ArrayList<Event>();
        Set<UUID> candidates = new LinkedHashSet<>();
        for (Line line : lines) {
            identity.add("line:" + line.inspectionItemId() + "|remaining:" + text(line.expectedRemaining())
                    + "|pass:" + text(line.pass()) + "|fail:" + text(line.fail()) + "|key:" + line.key());
            UUID passId = fullPass ? dispositionEventId(line.inspectionItemId(), line.key())
                    : derivedDispositionEventId(line.inspectionItemId(), line.key(), "-P");
            candidates.add(passId);
            if (line.pass().signum() > 0) events.add(new Event(passId, line.inspectionItemId(), "PASS", line.pass(), reason));
            if (!fullPass) {
                UUID failId = derivedDispositionEventId(line.inspectionItemId(), line.key(), "-F");
                // Also inspect the zero branch: removing an original FAIL/PASS
                // must not disguise a changed request as a fresh event.
                candidates.add(failId);
                if (line.fail().signum() > 0) events.add(new Event(failId, line.inspectionItemId(), "FAIL", line.fail(), reason));
            }
        }
        return new ProcurementInspectionBatchCommand(List.copyOf(lines), List.copyOf(events), Set.copyOf(candidates),
                CanonicalFingerprint.sha256(identity), fullPass);
    }

    private static String text(BigDecimal quantity) { return quantity.stripTrailingZeros().toPlainString(); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
