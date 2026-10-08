package com.uten.imp.features.stock;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import com.uten.imp.features.stock.dto.WeightInput;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/** Durable command identity; quantities and permissions remain owned by StockDocService. */
@Repository
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class StockDrawIssueBatchReceipts {
    private final EntityManager em;
    private final ObjectMapper mapper;

    record Command(String key, List<UUID> documents, String reason,
                   Map<UUID, StockDocIssueBatchRequest.ItemWeight> weights, String hash,
                   int protocolVersion, Map<UUID, String> reviews) {
        Command {
            documents = List.copyOf(documents);
            weights = Map.copyOf(weights);
            reviews = Map.copyOf(reviews);
        }
    }

    record ReceiptRead(String key, String requestHash, List<UUID> documents, StockDocIssueBatchResponse result) {
        ReceiptRead { documents = List.copyOf(documents); }
    }

    /** Read the original actor's committed snapshot without acquiring a write/production lock. */
    public Optional<ReceiptRead> findForRead(UUID actor, String rawKey) {
        String key = normalizeKey(rawKey);
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, request_snapshot::text, response_snapshot::text
                FROM stock_draw_issue_batches WHERE actor_user_id=:actor AND idempotency_key=:key
                """).setParameter("actor", actor).setParameter("key", key));
        if (rows.isEmpty()) return Optional.empty();
        try {
            var request = mapper.readTree((String) rows.getFirst()[1]);
            List<UUID> documents = new ArrayList<>();
            for (var id : request.path("documents")) documents.add(UUID.fromString(id.asText()));
            if (documents.isEmpty() || documents.size() > StockDocIssueBatchRequest.MAX_DOCUMENTS) {
                throw new IllegalStateException("批量出库回执缺少完整原单据清单");
            }
            return Optional.of(new ReceiptRead(key, (String) rows.getFirst()[0], documents,
                    mapper.readValue((String) rows.getFirst()[2], StockDocIssueBatchResponse.class)));
        } catch (JsonProcessingException | IllegalArgumentException failure) {
            throw new IllegalStateException("批量出库回执无法读取", failure);
        }
    }

    static String normalizeKey(String rawKey) {
        String key = rawKey == null ? "" : rawKey.strip();
        if (!key.matches("[A-Za-z0-9._:-]{8,128}")) throw validation("批量出库的防重复提交标识格式不正确");
        return key;
    }

    static Command normalize(StockDocIssueBatchRequest request) {
        if (request == null || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getDocIds() == null || request.getDocIds().isEmpty()) {
            throw validation("批量出库请求缺少防重复提交标识或单据清单");
        }
        String key = request.getIdempotencyKey().strip();
        if (key.length() < 8 || key.length() > 128 || !key.matches("[A-Za-z0-9._:-]+")) {
            throw validation("批量出库的防重复提交标识格式不正确");
        }
        var ids = new LinkedHashSet<>(request.getDocIds());
        if (ids.contains(null)) throw validation("批量出库单据清单含空值");
        if (ids.size() > StockDocIssueBatchRequest.MAX_DOCUMENTS) {
            throw validation("一次最多批量出库 " + StockDocIssueBatchRequest.MAX_DOCUMENTS + " 张领料单");
        }
        String reason = request.getReason() == null || request.getReason().isBlank()
                ? null : request.getReason().strip();
        if (reason != null && reason.length() > 200) throw validation("统一备注最多 200 字");
        if (request.getWeights() != null && request.getWeights().size() > RequestLimits.DOCUMENT_LINES) {
            throw validation("逐行重量最多 500 行");
        }
        var weights = StockDocService.batchIssueWeights(request.getWeights());
        var documents = ids.stream().sorted(Comparator.comparing(UUID::toString)).toList();
        int protocol = request.getProtocolVersion() == null ? 1 : request.getProtocolVersion();
        if (protocol != 1 && protocol != 2) throw validation("批量出库请求的版本不正确，请刷新页面后重试");
        Map<UUID, String> reviews = new java.util.TreeMap<>(Comparator.comparing(UUID::toString));
        if (request.getReviews() != null) {
            for (var review : request.getReviews()) {
                if (review == null || review.docId() == null || review.reviewToken() == null
                        || !review.reviewToken().matches("[0-9a-f]{64}")
                        || reviews.putIfAbsent(review.docId(), review.reviewToken()) != null) {
                    throw validation("批量出库勾选单据的版本信息有误，请刷新后重试");
                }
            }
        }
        if (protocol == 2 && !reviews.keySet().equals(ids)) {
            throw validation("批量出库的版本信息没有覆盖所选单据，请刷新后重试");
        }
        if (protocol == 1 && !reviews.isEmpty()) throw validation("版本信息与当前批量出库方式不匹配，请刷新页面后重试");
        List<String> parts = new ArrayList<>();
        parts.add("STOCK-DRAW-ISSUE-PARENT-V" + protocol);
        parts.add("reason:" + (reason == null ? "" : reason));
        documents.forEach(id -> parts.add("document:" + id));
        weights.forEach((id, weight) -> parts.add("weight:" + id + ":"
                + WeightInput.text(weight.weightKg()) + ":" + weight.qtyFromWeight()));
        reviews.forEach((id, token) -> parts.add("review:" + id + ":" + token));
        return new Command(key, documents, reason, weights, CanonicalFingerprint.sha256(parts), protocol, reviews);
    }

    /** Ordinary entry locks its command before the graph; Discovery uses a fresh server-owned inner key. */
    public Optional<StockDocIssueBatchResponse> lockAndFind(UUID actor, Command command) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,763))")
                .setParameter("key", actor + ":" + command.key()).getSingleResult();
        List<Object[]> previous = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, response_snapshot::text FROM stock_draw_issue_batches
                WHERE actor_user_id = :actor AND idempotency_key = :key
                """).setParameter("actor", actor).setParameter("key", command.key()));
        if (previous.isEmpty()) return Optional.empty();
        if (!command.hash().equals(previous.getFirst()[0])) {
            throw new ApiException(ErrorCode.CONFLICT, "相同批量键对应不同领料单、备注或重量，请重新核对");
        }
        try {
            var saved = mapper.readValue((String) previous.getFirst()[1], StockDocIssueBatchResponse.class);
            return Optional.of(new StockDocIssueBatchResponse(0, saved.skippedCount(),
                    saved.issuedCount() + saved.replayedCount(), true, List.of()));
        } catch (JsonProcessingException failure) {
            throw new IllegalStateException("批量出库回执无法读取", failure);
        }
    }

    /** Legacy per-document hashes cannot prove the original complete document set or reason. */
    public void rejectLegacyChildren(UUID actor, Command command) {
        List<String> pairs = new ArrayList<>();
        for (int i = 0; i < command.documents().size(); i++) {
            pairs.add("(stock_document_id = :document" + i + " AND idempotency_key = :child" + i + ")");
        }
        var query = em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM production_material_stock_events "
                + "WHERE event_type = 'ISSUE' AND (" + String.join(" OR ", pairs) + "))");
        for (int i = 0; i < command.documents().size(); i++) {
            UUID id = command.documents().get(i);
            query.setParameter("document" + i, id)
                    .setParameter("child" + i, StockDocService.batchChildIdempotencyKey(actor, command.key(), id));
        }
        if (Boolean.TRUE.equals(query.getSingleResult())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "此批量键存在旧版逐单出库记录但缺少完整批次回执，无法确认原单据范围及备注，请先核查历史出库记录；本批未新增出库");
        }
    }

    /** Persist only after every requested remainder is actually posted; all-skipped is also final. */
    public void record(UUID actor, UUID employee, Command command, StockDocIssueBatchResponse response) {
        String documents = "{" + String.join(",", command.documents().stream().map(UUID::toString).toList()) + "}";
        if (Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM stock_document_items item
                    WHERE item.doc_id = ANY(CAST(:documents AS uuid[])) AND NOT item.is_deleted
                      AND fn_production_draw_item_requested_qty(item.id) > COALESCE(item.issued_qty, 0))
                """).setParameter("documents", documents).getSingleResult())) {
            throw new ApiException(ErrorCode.CONFLICT, "本批仍有未实际出库的领料数量，整批未生效，请刷新后核对");
        }
        em.createNativeQuery("""
                INSERT INTO stock_draw_issue_batches(actor_user_id, actor_employee_id, idempotency_key,
                    request_hash, request_snapshot, response_snapshot, document_ids)
                VALUES(:actor, :employee, :key, :hash, CAST(:request AS jsonb), CAST(:response AS jsonb),
                    CAST(:documents AS uuid[]))
                """).setParameter("actor", actor).setParameter("employee", employee)
                .setParameter("key", command.key()).setParameter("hash", command.hash())
                .setParameter("request", mapper.valueToTree(command).toString())
                .setParameter("response", mapper.valueToTree(response).toString())
                .setParameter("documents", documents).executeUpdate();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
