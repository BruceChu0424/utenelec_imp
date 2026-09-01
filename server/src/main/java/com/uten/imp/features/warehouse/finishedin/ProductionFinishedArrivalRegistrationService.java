package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.PlaceSuggestionItemView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.PlaceSuggestionsView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.RememberPlacesResult;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Warehouse-owned destination/placement registration before production FQC. */
@Service
@RequiredArgsConstructor
public class ProductionFinishedArrivalRegistrationService {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionStockTaskAccessPolicy access;
    private final ProductionQualityInspectionPort qualityInspection;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public ArrivalRegistrationView detail(UUID reportId) {
        access.requireWarehouseTaskAccess("无权查看生产成品送检登记");
        return detailInternal(reportId);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PlaceSuggestionsView placeSuggestions(
            UUID reportId,
            UUID warehouseId) {
        access.requireWarehouseTaskAccess("无权查看生产成品库位建议");
        if (reportId == null || warehouseId == null) {
            throw validation("生产成品库位建议缺少报工单或仓库 UUID");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report_item.id,
                                       CASE
                                           WHEN preference.id IS NOT NULL
                                               THEN preference.place
                                           WHEN registration_history.place IS NOT NULL
                                               THEN registration_history.place
                                           ELSE NULLIF(BTRIM(goods.stock_place), '')
                                       END AS suggested_place,
                                       CASE
                                           WHEN preference.id IS NOT NULL
                                               THEN 'WAREHOUSE_PREFERENCE'
                                           WHEN registration_history.place IS NOT NULL
                                               THEN 'REGISTRATION_HISTORY'
                                           WHEN NULLIF(BTRIM(goods.stock_place), '') IS NOT NULL
                                               THEN 'GOODS_MASTER'
                                           ELSE 'NONE'
                                       END AS suggestion_source
                                FROM production_daily_reports report
                                JOIN production_daily_report_items report_item
                                  ON report_item.report_id = report.id
                                 AND report_item.is_deleted = FALSE
                                 AND report_item.execution_segment_id IS NOT NULL
                                JOIN goods goods
                                  ON goods.id = report_item.goods_id
                                 AND goods.is_deleted = FALSE
                                JOIN warehouses selected_warehouse
                                  ON selected_warehouse.id = :warehouseId
                                 AND selected_warehouse.is_deleted = FALSE
                                 AND selected_warehouse.is_accountable = TRUE
                                 AND COALESCE(selected_warehouse.status, '') <> '禁用'
                                LEFT JOIN warehouse_goods_place_preferences preference
                                 ON preference.warehouse_id = selected_warehouse.id
                                 AND preference.goods_id = report_item.goods_id
                                 AND preference.color_id
                                     IS NOT DISTINCT FROM report_item.color_id
                                LEFT JOIN LATERAL (
                                    SELECT latest_history.place
                                    FROM (
                                        SELECT history_registration.id,
                                               history_registration.created_at,
                                               MIN(BTRIM(
                                                   history_item.place_snapshot)) AS place,
                                               COUNT(DISTINCT BTRIM(
                                                   history_item.place_snapshot)) AS place_count
                                        FROM production_finished_arrival_registrations
                                                  history_registration
                                        JOIN production_finished_arrival_registration_items
                                                  history_item
                                          ON history_item.registration_id =
                                             history_registration.id
                                        JOIN production_daily_report_items history_report_item
                                          ON history_report_item.id =
                                             history_item.source_report_item_id
                                         AND history_report_item.goods_id =
                                             report_item.goods_id
                                         AND history_report_item.color_id
                                             IS NOT DISTINCT FROM report_item.color_id
                                        WHERE history_registration.warehouse_id =
                                              selected_warehouse.id
                                          AND history_registration.source_report_id <>
                                              report.id
                                        GROUP BY history_registration.id,
                                                 history_registration.created_at
                                        ORDER BY history_registration.created_at DESC,
                                                 history_registration.id DESC
                                        LIMIT 1
                                    ) latest_history
                                    WHERE latest_history.place_count = 1
                                ) registration_history ON preference.id IS NULL
                                LEFT JOIN production_finished_arrival_registrations
                                          visible_registration
                                  ON visible_registration.source_report_id = report.id
                                WHERE report.id = :reportId
                                  AND report.status = 1
                                  AND report.is_deleted = FALSE
                                  AND (
                                      visible_registration.id IS NOT NULL
                                      OR (
                                          NOT EXISTS (
                                              SELECT 1
                                              FROM production_daily_report_items
                                                       ineligible_item
                                              WHERE ineligible_item.report_id = report.id
                                                AND ineligible_item.is_deleted = FALSE
                                                AND ineligible_item.execution_segment_id IS NULL)
                                          AND NOT EXISTS (
                                              SELECT 1
                                              FROM production_fqc_inspections inspection
                                              WHERE inspection.source_report_id = report.id)
                                          AND NOT EXISTS (
                                              SELECT 1
                                              FROM production_fqc_legacy_exemptions exemption
                                              WHERE exemption.source_report_id = report.id)
                                      )
                                  )
                                ORDER BY report_item.line_no NULLS LAST,
                                         report_item.id
                                """)
                        .setParameter("reportId", reportId)
                        .setParameter("warehouseId", warehouseId));
        if (rows.isEmpty()) throw notFound();
        return new PlaceSuggestionsView(rows.stream()
                .map(row -> new PlaceSuggestionItemView(
                        (UUID) row[0], text(row[1]), text(row[2])))
                .toList());
    }

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve')")
    public ArrivalRegistrationView register(
            UUID reportId,
            ArrivalRegistrationRequest request) {
        tx.bind();
        access.requireWarehouseTaskAccess("无权登记生产成品送检");
        if (reportId == null || request == null) {
            throw validation("生产成品送检登记请求不能为空");
        }
        NormalizedRequest normalized = normalize(request);
        UUID actorId = currentUser.requireId();
        UUID receiverEmployeeId = currentUser.requireEmployeeId();

        lockCommand(actorId, normalized.idempotencyKey());
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, source_report_id, request_hash
                                FROM production_finished_arrival_registrations
                                WHERE created_by = :actorId
                                  AND idempotency_key = :idempotencyKey
                                FOR UPDATE
                                """)
                        .setParameter("actorId", actorId)
                        .setParameter(
                                "idempotencyKey", normalized.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] existing = replay.getFirst();
            if (!Objects.equals(existing[1], reportId)
                    || !Objects.equals(existing[2], normalized.requestHash())) {
                throw conflict("该仓库登记幂等键已用于不同请求");
            }
            return detailInternal(reportId);
        }

        Object[] report = lockApprovedReport(reportId);
        List<?> existingForReport = em.createNativeQuery("""
                        SELECT id
                        FROM production_finished_arrival_registrations
                        WHERE source_report_id = :reportId
                        FOR UPDATE
                        """)
                .setParameter("reportId", reportId)
                .getResultList();
        if (!existingForReport.isEmpty()) {
            throw conflict("该生产报工已由其他登记命令完成，请刷新");
        }
        requireNoQualityOrLegacyFacts(reportId);

        List<UUID> reportItemIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT id
                                FROM production_daily_report_items
                                WHERE report_id = :reportId
                                  AND is_deleted = FALSE
                                  AND execution_segment_id IS NOT NULL
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("reportId", reportId),
                UUID.class);
        if (reportItemIds.isEmpty()
                || !Set.copyOf(reportItemIds).equals(
                        normalized.places().keySet())) {
            throw validation("送检登记必须逐行精确覆盖当前报工全部明细");
        }

        WarehouseSnapshot warehouse = lockWarehouse(normalized.warehouseId());
        EmployeeSnapshot receiver = requireReceiver(receiverEmployeeId);
        UUID registrationId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_finished_arrival_registrations(
                            id, source_report_id, warehouse_id,
                            warehouse_code_snapshot, warehouse_name_snapshot,
                            receiver_employee_id, receiver_name_snapshot,
                            idempotency_key, request_hash, created_by)
                        VALUES (
                            :id, :reportId, :warehouseId,
                            :warehouseCode, :warehouseName,
                            :receiverId, :receiverName,
                            :idempotencyKey, :requestHash, :actorId)
                        """)
                .setParameter("id", registrationId)
                .setParameter("reportId", reportId)
                .setParameter("warehouseId", normalized.warehouseId())
                .setParameter("warehouseCode", warehouse.code())
                .setParameter("warehouseName", warehouse.name())
                .setParameter("receiverId", receiverEmployeeId)
                .setParameter("receiverName", receiver.name())
                .setParameter("idempotencyKey", normalized.idempotencyKey())
                .setParameter("requestHash", normalized.requestHash())
                .setParameter("actorId", actorId)
                .executeUpdate();

        normalized.places().entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(entry -> em.createNativeQuery("""
                                INSERT INTO production_finished_arrival_registration_items(
                                    id, registration_id, source_report_item_id,
                                    place_snapshot, created_by)
                                VALUES (
                                    gen_random_uuid(), :registrationId,
                                    :reportItemId, :place, :actorId)
                                """)
                        .setParameter("registrationId", registrationId)
                        .setParameter("reportItemId", entry.getKey())
                        .setParameter("place", entry.getValue())
                        .setParameter("actorId", actorId)
                        .executeUpdate());

        // Registration and every FQC PENDING fact commit or roll back together.
        qualityInspection.registerApprovedReport((UUID) report[0]);
        return detailInternal(reportId);
    }

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve')")
    public RememberPlacesResult rememberPlaces(UUID reportId) {
        tx.bind();
        access.requireWarehouseTaskAccess("无权记忆生产成品库位建议");
        if (reportId == null) {
            throw validation("生产成品库位记忆缺少报工单 UUID");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT registration.id,
                                       registration.warehouse_id,
                                       registration.created_at,
                                       registration_item.source_report_item_id,
                                       report_item.goods_id,
                                       report_item.color_id,
                                       registration_item.place_snapshot,
                                       goods.code,
                                       goods.name
                                FROM production_finished_arrival_registrations registration
                                JOIN production_daily_reports report
                                  ON report.id = registration.source_report_id
                                 AND report.status = 1
                                 AND report.is_deleted = FALSE
                                JOIN production_finished_arrival_registration_items
                                          registration_item
                                  ON registration_item.registration_id = registration.id
                                JOIN production_daily_report_items report_item
                                  ON report_item.id = registration_item.source_report_item_id
                                 AND report_item.report_id = report.id
                                 AND report_item.is_deleted = FALSE
                                JOIN goods goods
                                  ON goods.id = report_item.goods_id
                                 AND goods.is_deleted = FALSE
                                WHERE registration.source_report_id = :reportId
                                ORDER BY report_item.goods_id,
                                         report_item.color_id NULLS FIRST,
                                         report_item.id
                                """)
                        .setParameter("reportId", reportId));
        if (rows.isEmpty()) throw notFound();

        UUID registrationId = (UUID) rows.getFirst()[0];
        UUID warehouseId = (UUID) rows.getFirst()[1];
        OffsetDateTime registeredAt = offsetDateTime(rows.getFirst()[2]);
        RememberPlan plan = buildRememberPlan(rows.stream()
                .map(row -> new RememberPlaceSource(
                        (UUID) row[4], (UUID) row[5], text(row[6]),
                        text(row[7]), text(row[8])))
                .toList());

        UUID actorId = currentUser.requireId();
        UUID employeeId = currentUser.requireEmployeeId();
        int remembered = 0;
        int unchanged = 0;
        for (RememberCandidate candidate : plan.candidates()) {
            List<?> changed = em.createNativeQuery("""
                            INSERT INTO warehouse_goods_place_preferences(
                                id, warehouse_id, goods_id, color_id, place,
                                selection_count, version,
                                source_kind, source_registration_id,
                                source_iqc_batch_id, source_registered_at,
                                last_selected_by, last_selected_at,
                                created_by, updated_by)
                            VALUES (
                                gen_random_uuid(), :warehouseId, :goodsId,
                                :colorId, :place, 1, 0,
                                'FINISHED_ARRIVAL', :registrationId,
                                NULL, :registeredAt,
                                :employeeId, now(), :actorId, :actorId)
                            ON CONFLICT ON CONSTRAINT
                                warehouse_goods_place_preference_dimension_uk
                            DO UPDATE SET
                                place = EXCLUDED.place,
                                selection_count =
                                    warehouse_goods_place_preferences.selection_count + 1,
                                version = warehouse_goods_place_preferences.version + 1,
                                source_kind = EXCLUDED.source_kind,
                                source_registration_id =
                                    EXCLUDED.source_registration_id,
                                source_iqc_batch_id =
                                    EXCLUDED.source_iqc_batch_id,
                                source_registered_at = EXCLUDED.source_registered_at,
                                last_selected_by = EXCLUDED.last_selected_by,
                                last_selected_at = now(),
                                updated_by = EXCLUDED.updated_by
                            WHERE (
                                warehouse_goods_place_preferences.source_registered_at,
                                COALESCE(
                                    warehouse_goods_place_preferences.source_registration_id,
                                    warehouse_goods_place_preferences.source_iqc_batch_id)
                            ) < (
                                EXCLUDED.source_registered_at,
                                EXCLUDED.source_registration_id
                            )
                            RETURNING id
                            """)
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", candidate.goodsId())
                    .setParameter("colorId", candidate.colorId())
                    .setParameter("place", candidate.place())
                    .setParameter("registrationId", registrationId)
                    .setParameter("registeredAt", registeredAt)
                    .setParameter("employeeId", employeeId)
                    .setParameter("actorId", actorId)
                    .getResultList();
            if (changed.isEmpty()) {
                unchanged++;
            } else {
                remembered++;
            }
        }
        return new RememberPlacesResult(
                remembered, unchanged, plan.ambiguous(), plan.warnings());
    }

    private ArrivalRegistrationView detailInternal(UUID reportId) {
        if (reportId == null) throw notFound();
        EmployeeSnapshot currentReceiver = requireReceiver(
                currentUser.requireEmployeeId());
        List<Object[]> headers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report.id, report.bill_no,
                                       report.bill_date, report.department_id,
                                       report.workshop_name,
                                       registration.id,
                                       registration.warehouse_id,
                                       registration.warehouse_code_snapshot,
                                       registration.warehouse_name_snapshot,
                                       registration.receiver_employee_id,
                                       registration.receiver_name_snapshot,
                                       registration.created_at
                                FROM production_daily_reports report
                                LEFT JOIN production_finished_arrival_registrations registration
                                  ON registration.source_report_id = report.id
                                WHERE report.id = :reportId
                                  AND report.status = 1
                                  AND report.is_deleted = FALSE
                                """)
                        .setParameter("reportId", reportId));
        if (headers.size() != 1) throw notFound();
        Object[] header = headers.getFirst();
        boolean registered = header[5] != null;
        if (!registered && !isPendingRegistration(reportId)) throw notFound();

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report_item.id, report_item.line_no,
                                       report_item.plan_item_id,
                                       report_item.execution_segment_id,
                                       plan.id, plan.bill_no,
                                       report_item.goods_id,
                                       goods.code, goods.name,
                                       report_item.color_id, color.name,
                                       report_item.unit_id, unit.name,
                                       report_item.qty,
                                       registration_item.place_snapshot,
                                       goods.stock_place
                                FROM production_daily_report_items report_item
                                JOIN production_plan_items plan_item
                                  ON plan_item.id = report_item.plan_item_id
                                 AND plan_item.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = plan_item.plan_id
                                 AND plan.is_deleted = FALSE
                                JOIN goods goods ON goods.id = report_item.goods_id
                                LEFT JOIN colors color
                                  ON color.id = report_item.color_id
                                LEFT JOIN units unit
                                  ON unit.id = report_item.unit_id
                                LEFT JOIN production_finished_arrival_registration_items
                                          registration_item
                                  ON registration_item.source_report_item_id = report_item.id
                                WHERE report_item.report_id = :reportId
                                  AND report_item.is_deleted = FALSE
                                ORDER BY report_item.line_no NULLS LAST,
                                         report_item.id
                                """)
                        .setParameter("reportId", reportId));
        if (rows.isEmpty()) throw notFound();
        List<ArrivalRegistrationItemView> items = rows.stream()
                .map(row -> new ArrivalRegistrationItemView(
                        (UUID) row[0], integer(row[1]), (UUID) row[2],
                        (UUID) row[3], (UUID) row[4], text(row[5]),
                        (UUID) row[6], text(row[7]), text(row[8]),
                        (UUID) row[9], text(row[10]), (UUID) row[11],
                        text(row[12]), decimal(row[13]), text(row[14]),
                        text(row[15])))
                .toList();
        UUID receiverId = registered
                ? (UUID) header[9] : currentReceiver.id();
        String receiverName = registered
                ? text(header[10]) : currentReceiver.name();
        return new ArrivalRegistrationView(
                (UUID) header[5], registered, (UUID) header[0],
                text(header[1]), localDate(header[2]), (UUID) header[3],
                text(header[4]), (UUID) header[6], text(header[7]),
                text(header[8]), receiverId, receiverName,
                offsetDateTime(header[11]), items);
    }

    private Object[] lockApprovedReport(UUID reportId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status, is_deleted
                                FROM production_daily_reports
                                WHERE id = :reportId
                                FOR UPDATE
                                """)
                        .setParameter("reportId", reportId));
        if (rows.size() != 1
                || ((Number) rows.getFirst()[1]).shortValue() != 1
                || Boolean.TRUE.equals(rows.getFirst()[2])) {
            throw conflict("仅已审核且未红冲的生产报工可登记送检");
        }
        return rows.getFirst();
    }

    private void requireNoQualityOrLegacyFacts(UUID reportId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_daily_report_items report_item
                        WHERE report_item.report_id = :reportId
                          AND report_item.is_deleted = FALSE
                          AND (
                              EXISTS (
                                  SELECT 1
                                  FROM production_fqc_inspections inspection
                                  WHERE inspection.source_report_item_id = report_item.id)
                              OR EXISTS (
                                  SELECT 1
                                  FROM production_fqc_legacy_exemptions exemption
                                  WHERE exemption.source_report_item_id = report_item.id)
                              OR report_item.execution_segment_id IS NULL)
                        """)
                .setParameter("reportId", reportId)
                .getSingleResult();
        if (count == null || count.longValue() != 0) {
            throw conflict("该报工已有 FQC/历史切点事实，不能重复登记送检");
        }
    }

    private boolean isPendingRegistration(UUID reportId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_daily_reports report
                        WHERE report.id = :reportId
                          AND report.status = 1
                          AND report.is_deleted = FALSE
                          AND EXISTS (
                              SELECT 1
                              FROM production_daily_report_items report_item
                              WHERE report_item.report_id = report.id
                                AND report_item.is_deleted = FALSE)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_daily_report_items report_item
                              WHERE report_item.report_id = report.id
                                AND report_item.is_deleted = FALSE
                                AND report_item.execution_segment_id IS NULL)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_fqc_inspections inspection
                              WHERE inspection.source_report_id = report.id)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_fqc_legacy_exemptions exemption
                              WHERE exemption.source_report_id = report.id)
                        """)
                .setParameter("reportId", reportId)
                .getSingleResult();
        return count != null && count.longValue() == 1;
    }

    private WarehouseSnapshot lockWarehouse(UUID warehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT code, name
                                FROM warehouses
                                WHERE id = :warehouseId
                                  AND is_deleted = FALSE
                                  AND is_accountable = TRUE
                                  AND COALESCE(status, '') <> '禁用'
                                FOR UPDATE
                                """)
                        .setParameter("warehouseId", warehouseId));
        if (rows.size() != 1 || text(rows.getFirst()[1]) == null
                || text(rows.getFirst()[1]).isBlank()) {
            throw validation("目标仓库不存在、已停用或不参与库存核算");
        }
        return new WarehouseSnapshot(
                text(rows.getFirst()[0]), text(rows.getFirst()[1]));
    }

    private EmployeeSnapshot requireReceiver(UUID employeeId) {
        List<?> names = em.createNativeQuery("""
                        SELECT full_name
                        FROM employees
                        WHERE id = :employeeId
                          AND is_deleted = FALSE
                          AND status <> 'resigned'
                        """)
                .setParameter("employeeId", employeeId)
                .getResultList();
        if (names.size() != 1 || text(names.getFirst()) == null
                || text(names.getFirst()).isBlank()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前收货人员无效");
        }
        return new EmployeeSnapshot(employeeId, text(names.getFirst()));
    }

    private void lockCommand(UUID actorId, String idempotencyKey) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(:lockKey, CAST(430 AS bigint)))
                        """)
                .setParameter("lockKey",
                        "PRODUCTION_FINISHED_ARRIVAL:"
                                + actorId + ':' + idempotencyKey)
                .getSingleResult();
    }

    static NormalizedRequest normalize(ArrivalRegistrationRequest request) {
        if (request == null || request.idempotencyKey() == null
                || request.warehouseId() == null || request.items() == null
                || request.items().isEmpty()) {
            throw validation("送检登记缺少幂等键、目标仓或明细");
        }
        String key = request.idempotencyKey().strip();
        if (key.length() < 8 || key.length() > 128
                || !key.matches("[A-Za-z0-9._:-]+")) {
            throw validation("送检登记幂等键格式无效");
        }
        Map<UUID, String> places = new LinkedHashMap<>();
        if (request.items().stream().anyMatch(Objects::isNull)) {
            throw validation("送检登记行不能为空");
        }
        request.items().stream()
                .sorted(Comparator.comparing(
                        ArrivalRegistrationItemRequest::reportItemId,
                        Comparator.nullsLast(Comparator.naturalOrder())))
                .forEach(item -> {
                    if (item == null || item.reportItemId() == null
                            || item.place() == null) {
                        throw validation("送检登记行缺少报工明细 UUID 或库位");
                    }
                    String place = item.place().strip();
                    if (place.isEmpty() || place.length() > 100) {
                        throw validation("库位必须为 1至100 个字符");
                    }
                    if (places.putIfAbsent(item.reportItemId(), place) != null) {
                        throw validation("同一报工明细不能重复登记库位");
                    }
                });
        List<String> hashParts = new ArrayList<>();
        hashParts.add("PRODUCTION-FINISHED-ARRIVAL-REGISTRATION-V1");
        hashParts.add(request.warehouseId().toString());
        places.forEach((id, place) -> hashParts.add(id + "|" + place));
        return new NormalizedRequest(
                key, request.warehouseId(), Map.copyOf(places),
                CanonicalFingerprint.sha256(hashParts));
    }

    static RememberPlan buildRememberPlan(List<RememberPlaceSource> sources) {
        Map<PlaceDimension, RememberAccumulator> grouped = new LinkedHashMap<>();
        if (sources == null) {
            return new RememberPlan(List.of(), 0, List.of());
        }
        for (RememberPlaceSource source : sources) {
            if (source == null || source.goodsId() == null
                    || source.place() == null) {
                throw validation("库位记忆来源缺少货品 UUID 或登记快照");
            }
            String place = source.place().strip();
            if (place.isEmpty() || place.length() > 100) {
                throw validation("库位记忆来源必须为 1至100 个字符");
            }
            PlaceDimension dimension = new PlaceDimension(
                    source.goodsId(), source.colorId());
            RememberAccumulator accumulator = grouped.computeIfAbsent(
                    dimension,
                    ignored -> new RememberAccumulator(
                            source.goodsId(), source.colorId(),
                            source.goodsCode(), source.goodsName()));
            accumulator.places().add(place);
        }

        List<RememberCandidate> candidates = new ArrayList<>();
        List<String> warnings = new ArrayList<>();
        int ambiguous = 0;
        for (RememberAccumulator accumulator : grouped.values()) {
            if (accumulator.places().size() == 1) {
                candidates.add(new RememberCandidate(
                        accumulator.goodsId(), accumulator.colorId(),
                        accumulator.places().iterator().next()));
                continue;
            }
            ambiguous++;
            List<String> places = accumulator.places().stream()
                    .sorted()
                    .toList();
            warnings.add("货品 " + accumulator.displayName()
                    + " 在同一登记中存在不同库位 "
                    + String.join(" / ", places)
                    + "，未记忆默认库位");
        }
        return new RememberPlan(candidates, ambiguous, warnings);
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((Date) value).toLocalDate();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        return value == null ? null
                : NativeValueConverters.toOffsetDateTime(value);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static Integer integer(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "生产成品送检登记任务不存在");
    }

    record NormalizedRequest(
            String idempotencyKey,
            UUID warehouseId,
            Map<UUID, String> places,
            String requestHash) {
    }

    record RememberPlaceSource(
            UUID goodsId,
            UUID colorId,
            String place,
            String goodsCode,
            String goodsName) {
    }

    record RememberCandidate(UUID goodsId, UUID colorId, String place) {
    }

    record RememberPlan(
            List<RememberCandidate> candidates,
            int ambiguous,
            List<String> warnings) {

        RememberPlan {
            candidates = List.copyOf(candidates);
            warnings = List.copyOf(warnings);
        }
    }

    private record PlaceDimension(UUID goodsId, UUID colorId) {
    }

    private record RememberAccumulator(
            UUID goodsId,
            UUID colorId,
            String goodsCode,
            String goodsName,
            LinkedHashSet<String> places) {

        RememberAccumulator(
                UUID goodsId,
                UUID colorId,
                String goodsCode,
                String goodsName) {
            this(goodsId, colorId, goodsCode, goodsName,
                    new LinkedHashSet<>());
        }

        String displayName() {
            if (goodsCode != null && !goodsCode.isBlank()) {
                return goodsCode.strip();
            }
            if (goodsName != null && !goodsName.isBlank()) {
                return goodsName.strip();
            }
            return goodsId.toString();
        }
    }

    private record WarehouseSnapshot(String code, String name) {
    }

    private record EmployeeSnapshot(UUID id, String name) {
    }
}
