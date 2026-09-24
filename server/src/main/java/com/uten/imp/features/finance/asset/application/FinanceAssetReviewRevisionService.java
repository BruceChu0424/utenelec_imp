package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Uses append-only asset business events, never mutable master rows or generic audit prose as history. */
@Service
@RequiredArgsConstructor
public class FinanceAssetReviewRevisionService {
    private final EntityManager em;
    private final ObjectMapper mapper;

    @Transactional(readOnly = true)
    public JsonNode capture(UUID id, boolean deferred) {
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        String person = deferred ? "a.responsible_employee_id" : "a.custodian_employee_id";
        String specific = deferred ? """
                'totalAmount', a.total_amount::text,
                'responsibleEmployeeId', a.responsible_employee_id,
                'benefitStartDate', a.service_start_on, 'benefitEndDate', a.benefit_end_on
                """ : """
                'originalValue', a.original_value::text, 'salvageRate', a.salvage_rate::text,
                'acquisitionDate', a.acquired_on, 'acceptanceDate', a.accepted_on,
                'readyForUseDate', a.ready_for_use_on, 'serialNumber', a.serial_number,
                'assetTag', a.asset_tag
                """;
        String json = (String) em.createNativeQuery("""
                SELECT jsonb_build_object(
                    'schemaVersion', 1, 'objectType', :type,
                    'code', a.code, 'name', a.name,
                    'categoryId', a.category_id, 'categoryName', category.name,
                    'departmentId', a.department_id, 'departmentName', department.name,
                    'custodianId', %s, 'custodianName', employee.full_name,
                    'location', a.location_text, 'costCenterCode', a.cost_center_code,
                    'usefulMonths', a.useful_months, 'startPeriod', a.start_period,
                    'sourceType', a.source_type, 'sourceId', a.source_id,
                    'sourceRef', a.source_ref, 'sourceLineRef', a.source_line_ref,
                    'sourceDocumentDate', a.source_document_date, 'remark', a.remark,
                    %s)::text
                FROM %s a
                LEFT JOIN finance_asset_categories category ON category.id=a.category_id
                LEFT JOIN departments department ON department.id=a.department_id
                LEFT JOIN employees employee ON employee.id=%s
                WHERE a.id=:id AND NOT a.is_deleted
                """.formatted(person, specific, table, person))
                .setParameter("type", deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET")
                .setParameter("id", id).getSingleResult();
        return parse(json);
    }

    @Transactional(readOnly = true)
    public List<AssetWorkbenchResponses.ReviewRevision> read(String objectType, UUID objectId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT event_type, payload::text, effective_date, description
                FROM finance_asset_events
                WHERE object_type=:type AND object_id=:id
                  AND event_type IN ('SUBMITTED','REJECTED','DISPOSAL_REQUESTED','TERMINATION_REQUESTED')
                ORDER BY occurred_at, COALESCE((payload->>'reviewRevision')::bigint,0), id
                """).setParameter("type", objectType).setParameter("id", objectId).getResultList();
        return project(rows);
    }

    List<AssetWorkbenchResponses.ReviewRevision> project(List<Object[]> rows) {
        Map<String, List<JsonNode>> submissions = new LinkedHashMap<>();
        for (Object[] row : rows) {
            String type = (String) row[0];
            JsonNode payload = parse((String) row[1]);
            if ("REJECTED".equals(type)) {
                // On upgrade a still-frozen pending card may first acquire its
                // authentic commercial image at rejection, before it becomes editable.
                List<JsonNode> recognition = submissions.get("RECOGNITION");
                JsonNode recovered = recognitionSnapshot(payload);
                if ("RECOGNITION".equals(payload.path("workflow").asText()) && recovered != null
                        && recognition != null && !recognition.isEmpty() && recognition.getLast() == null) {
                    recognition.set(recognition.size()-1, recovered);
                }
                continue;
            }
            String workflow = switch (type) {
                case "SUBMITTED" -> "RECOGNITION";
                case "DISPOSAL_REQUESTED" -> "DISPOSAL";
                case "TERMINATION_REQUESTED" -> "TERMINATION";
                default -> throw new IllegalStateException("Unexpected asset review event: " + type);
            };
            JsonNode snapshot = "RECOGNITION".equals(workflow) ? recognitionSnapshot(payload)
                    : requestSnapshot(payload, row[2], row[3], workflow);
            submissions.computeIfAbsent(workflow, ignored -> new ArrayList<>()).add(snapshot);
        }
        List<AssetWorkbenchResponses.ReviewRevision> revisions = new ArrayList<>();
        submissions.forEach((workflow, versions) -> {
            int size = versions.size();
            revisions.add(new AssetWorkbenchResponses.ReviewRevision(workflow, size > 1,
                    size > 1 ? jsonOrNull(versions.get(size-2)) : null, jsonOrNull(versions.getLast())));
        });
        return List.copyOf(revisions);
    }

    private static JsonNode recognitionSnapshot(JsonNode payload) {
        JsonNode snapshot = payload.path("submissionSnapshot");
        return snapshot.isObject() && snapshot.path("schemaVersion").asInt() == 1 ? snapshot : null;
    }

    private static JsonNode requestSnapshot(JsonNode payload, Object date, Object reason, String workflow) {
        if (!payload.isObject() || !payload.has("evidenceReference")
                || ("DISPOSAL".equals(workflow) && !payload.has("proceedsAmount"))) return null;
        ObjectNode snapshot = payload.deepCopy();
        snapshot.remove("reviewRevision");
        if (snapshot.path("proceedsAmount").isNumber()) {
            snapshot.put("proceedsAmount", snapshot.path("proceedsAmount").decimalValue().toPlainString());
        }
        snapshot.put("schemaVersion", 1);
        snapshot.put("effectiveDate", date == null ? null : date.toString());
        snapshot.put("reason", reason == null ? null : reason.toString());
        return snapshot;
    }

    private static String jsonOrNull(JsonNode value) { return value == null ? null : value.toString(); }

    private JsonNode parse(String json) {
        try { return mapper.reader().with(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).readTree(json); }
        catch (java.io.IOException failure) { throw new IllegalStateException("资产业务提交快照无效", failure); }
    }
}
