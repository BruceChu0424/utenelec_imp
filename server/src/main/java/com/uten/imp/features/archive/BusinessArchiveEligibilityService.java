package com.uten.imp.features.archive;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 归档资格评估与采购订单完整对象打包试点（B3，V955）。
 *
 * <p>资格口径（07 方案 7.2，试点只做「登记 + 复制校验」，不搬移不删除）：已审已结案、
 * 质量案件全部终结、无草稿收货/退回、关联应付台账全部结清、最晚结清日满候选期
 * （默认 24 个月，只是候选门槛不是删除期限）。缺可信结清日（该订单从无台账）的
 * 旧单只登记「结清日期不可得」，不拿创建日补。
 *
 * <p>打包在单事务可重复读快照内组装整个对象族（原单/明细/审批/收货/退回/台账/质量
 * 案件/附件原件引用），SHA-256 随行并在落库后复核存储字节；重跑出新版本并置旧版
 * SUPERSEDED——中断恢复=重放，回退=按包身份删除包行，业务数据永远不动。
 */
@Slf4j
@Service
public class BusinessArchiveEligibilityService {

    static final String FAMILY_PURCHASE_ORDER = "PURCHASE_ORDER";
    static final String POLICY_VERSION = "purchase-order-pilot-v1";

    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final int settledMonths;

    public BusinessArchiveEligibilityService(
            JdbcTemplate jdbc,
            ObjectMapper mapper,
            @Value("${uten.archive.eligibility.settled-months:24}") int settledMonths) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.settledMonths = Math.max(1, settledMonths);
    }

    public record Evaluation(
            UUID objectId, String billNo, boolean eligible,
            List<String> blockedReasons, LocalDate finalSettledOn) {}

    /** 扫描已审已结案采购订单并整行重算资格登记；返回本次评估结果（按单号升序，有界）。 */
    @Transactional
    public List<Evaluation> evaluatePurchaseOrders(int limit) {
        int bounded = Math.max(1, Math.min(limit, 1_000));
        LocalDate cutoff = LocalDate.now().minusMonths(settledMonths);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                WITH candidates AS (
                    SELECT o.id, o.bill_no, o.bill_date
                    FROM purchase_orders o
                    WHERE o.status = 1 AND o.is_closed AND NOT o.is_deleted
                    ORDER BY o.bill_date, o.id
                    LIMIT ?
                )
                SELECT c.id, c.bill_no,
                       COALESCE(f.open_quality_cases, 0) AS open_quality_cases,
                       COALESCE(f.draft_receipts, 0) AS draft_receipts,
                       COALESCE(f.draft_returns, 0) AS draft_returns,
                       COALESCE(f.ledger_rows, 0) AS ledger_rows,
                       COALESCE(f.unsettled_rows, 0) AS unsettled_rows,
                       f.final_settled_on
                FROM candidates c
                CROSS JOIN LATERAL (
                    SELECT
                        (SELECT count(*) FROM procurement_iqc_rejection_cases q
                          WHERE q.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                     WHERE oi.order_id = c.id)
                            AND q.status NOT IN ('CREDIT_CONFIRMED','CLOSED_NO_CREDIT','REVERSED')
                        ) AS open_quality_cases,
                        (SELECT count(*) FROM purchase_receipts r
                          WHERE NOT r.is_deleted AND r.status <> 1
                            AND EXISTS (SELECT 1 FROM purchase_receipt_items ri
                                         WHERE ri.receipt_id = r.id
                                           AND ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                                    WHERE oi.order_id = c.id))
                        ) AS draft_receipts,
                        (SELECT count(*) FROM purchase_returns t
                          WHERE NOT t.is_deleted AND t.status <> 1
                            AND EXISTS (SELECT 1 FROM purchase_return_items ti
                                         WHERE ti.return_id = t.id
                                           AND ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                                    WHERE oi.order_id = c.id))
                        ) AS draft_returns,
                        (SELECT count(*) FROM ar_ap_ledger l
                          WHERE NOT l.is_deleted AND (
                              (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                  (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                    WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id)))
                           OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                  (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                    WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id))))
                        ) AS ledger_rows,
                        (SELECT count(*) FROM ar_ap_ledger l
                          WHERE NOT l.is_deleted AND NOT l.is_settled AND (
                              (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                  (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                    WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id)))
                           OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                  (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                    WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id))))
                        ) AS unsettled_rows,
                        (SELECT max(l.settled_date) FROM ar_ap_ledger l
                          WHERE NOT l.is_deleted AND l.is_settled AND (
                              (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                  (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                    WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id)))
                           OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                  (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                    WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi
                                                               WHERE oi.order_id = c.id))))
                        ) AS final_settled_on
                ) f
                """, bounded);

        List<Evaluation> evaluations = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            UUID orderId = (UUID) row.get("id");
            String billNo = String.valueOf(row.get("bill_no"));
            long openQuality = ((Number) row.get("open_quality_cases")).longValue();
            long draftReceipts = ((Number) row.get("draft_receipts")).longValue();
            long draftReturns = ((Number) row.get("draft_returns")).longValue();
            long ledgerRows = ((Number) row.get("ledger_rows")).longValue();
            long unsettled = ((Number) row.get("unsettled_rows")).longValue();
            LocalDate finalSettled = row.get("final_settled_on") == null
                    ? null
                    : (row.get("final_settled_on") instanceof java.sql.Date sqlDate
                            ? sqlDate.toLocalDate()
                            : LocalDate.parse(String.valueOf(row.get("final_settled_on"))));

            List<String> reasons = new ArrayList<>();
            if (openQuality > 0) reasons.add("OPEN_QUALITY_CASES");
            if (draftReceipts > 0) reasons.add("DRAFT_RECEIPTS");
            if (draftReturns > 0) reasons.add("DRAFT_RETURNS");
            if (unsettled > 0) reasons.add("UNSETTLED_LEDGER");
            if (ledgerRows == 0) reasons.add("NO_SETTLED_EVIDENCE");
            if (ledgerRows > 0 && finalSettled != null && finalSettled.isAfter(cutoff)) {
                reasons.add("SETTLED_TOO_RECENT");
            }
            if (ledgerRows > 0 && finalSettled == null && unsettled == 0) {
                reasons.add("SETTLED_DATE_MISSING");
            }
            boolean eligible = reasons.isEmpty();

            Map<String, Object> facts = new LinkedHashMap<>();
            facts.put("billNo", billNo);
            facts.put("openQualityCases", openQuality);
            facts.put("draftReceipts", draftReceipts);
            facts.put("draftReturns", draftReturns);
            facts.put("ledgerRows", ledgerRows);
            facts.put("unsettledLedgerRows", unsettled);
            facts.put("settledCutoff", cutoff.toString());

            jdbc.update("""
                    INSERT INTO business_archive_eligibility(
                        object_family, object_id, evaluated_at, eligible,
                        blocked_reasons, final_settled_on, facts)
                    VALUES (?, ?, now(), ?, CAST(? AS jsonb), ?, CAST(? AS jsonb))
                    ON CONFLICT (object_family, object_id) DO UPDATE SET
                        evaluated_at = now(),
                        eligible = EXCLUDED.eligible,
                        blocked_reasons = EXCLUDED.blocked_reasons,
                        final_settled_on = EXCLUDED.final_settled_on,
                        facts = EXCLUDED.facts
                    """,
                    FAMILY_PURCHASE_ORDER, orderId, eligible,
                    toJson(reasons), finalSettled, toJson(facts));
            evaluations.add(new Evaluation(orderId, billNo, eligible, reasons, finalSettled));
        }
        return evaluations;
    }

    /**
     * 为已评估合格的订单打包完整对象族快照。单事务可重复读快照内组装、
     * 打包前即时复核资格（评估与打包之间发生的迟到收退/立账会被拦下）、
     * SHA-256 随行并复核落库字节；同摘要已存在 VERIFIED 包时幂等跳过。
     */
    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public PackageOutcome packagePurchaseOrder(UUID orderId) {
        List<Evaluation> recheck = evaluateOne(orderId);
        if (recheck.size() != 1 || !recheck.get(0).eligible()) {
            return new PackageOutcome(orderId, "SKIPPED_NOT_ELIGIBLE", null, null);
        }
        String payloadText = assemblePayload(orderId);
        String digest = sha256(payloadText);
        Map<String, Object> counts = lineCounts(orderId);

        String existingDigest = jdbc.query("""
                SELECT payload_sha256 FROM business_archive_packages
                WHERE object_family = ? AND object_id = ? AND status = 'VERIFIED'
                ORDER BY package_version DESC LIMIT 1
                """, (rs, n) -> rs.getString(1), FAMILY_PURCHASE_ORDER, orderId)
                .stream().findFirst().orElse(null);
        if (digest.equals(existingDigest)) {
            return new PackageOutcome(orderId, "UNCHANGED", digest, counts);
        }
        jdbc.update("UPDATE business_archive_packages SET status = 'SUPERSEDED' "
                + "WHERE object_family = ? AND object_id = ? AND status = 'VERIFIED'",
                FAMILY_PURCHASE_ORDER, orderId);
        int nextVersion = 1 + jdbc.query("""
                        SELECT COALESCE(max(package_version), 0) FROM business_archive_packages
                        WHERE object_family = ? AND object_id = ?
                        """,
                        (rs, n) -> rs.getInt(1), FAMILY_PURCHASE_ORDER, orderId)
                .stream().findFirst().orElse(0);
        jdbc.update("""
                INSERT INTO business_archive_packages(
                    object_family, object_id, package_version, policy_version,
                    payload, payload_sha256, attachment_refs, line_counts, created_by)
                VALUES (?, ?, ?, ?, CAST(? AS jsonb), ?, CAST(? AS jsonb), CAST(? AS jsonb), NULL)
                """,
                FAMILY_PURCHASE_ORDER, orderId, nextVersion, POLICY_VERSION,
                payloadText, digest, attachmentRefsJson(orderId), toJson(counts));
        // 复制校验：落库字节回读后重新摘要，必须与随行摘要一致。
        String stored = jdbc.queryForObject("""
                SELECT payload::text FROM business_archive_packages
                WHERE object_family = ? AND object_id = ? AND package_version = ?
                """, String.class, FAMILY_PURCHASE_ORDER, orderId, nextVersion);
        if (!digest.equals(sha256(stored))) {
            throw new IllegalStateException("归档包落库字节与摘要不一致: " + orderId);
        }
        return new PackageOutcome(orderId, "PACKAGED", digest, counts);
    }

    /** 打包前即时资格复核（同评估口径，单订单）。 */
    private List<Evaluation> evaluateOne(UUID orderId) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT o.id, o.bill_no, o.status, o.is_closed, o.is_deleted,
                       (SELECT count(*) FROM procurement_iqc_rejection_cases q
                         WHERE q.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id)
                           AND q.status NOT IN ('CREDIT_CONFIRMED','CLOSED_NO_CREDIT','REVERSED')) AS open_quality_cases,
                       (SELECT count(*) FROM purchase_receipts r
                         WHERE NOT r.is_deleted AND r.status <> 1
                           AND EXISTS (SELECT 1 FROM purchase_receipt_items ri
                                        WHERE ri.receipt_id = r.id
                                          AND ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))) AS draft_receipts,
                       (SELECT count(*) FROM purchase_returns t
                         WHERE NOT t.is_deleted AND t.status <> 1
                           AND EXISTS (SELECT 1 FROM purchase_return_items ti
                                        WHERE ti.return_id = t.id
                                          AND ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))) AS draft_returns,
                       (SELECT count(*) FROM ar_ap_ledger l
                         WHERE NOT l.is_deleted AND (
                             (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                 (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                   WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id)))
                          OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                 (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                   WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))))) AS ledger_rows,
                       (SELECT count(*) FROM ar_ap_ledger l
                         WHERE NOT l.is_deleted AND NOT l.is_settled AND (
                             (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                 (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                   WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id)))
                          OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                 (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                   WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))))) AS unsettled_rows,
                       (SELECT max(l.settled_date) FROM ar_ap_ledger l
                         WHERE NOT l.is_deleted AND l.is_settled AND (
                             (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                 (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                   WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id)))
                          OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                 (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                   WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))))) AS final_settled_on
                FROM purchase_orders o WHERE o.id = ?
                """, orderId);
        LocalDate cutoff = LocalDate.now().minusMonths(settledMonths);
        List<Evaluation> result = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            String billNo = String.valueOf(row.get("bill_no"));
            long ledgerRows = ((Number) row.get("ledger_rows")).longValue();
            LocalDate finalSettled = row.get("final_settled_on") == null ? null
                    : (row.get("final_settled_on") instanceof java.sql.Date sqlDate
                            ? sqlDate.toLocalDate()
                            : LocalDate.parse(String.valueOf(row.get("final_settled_on"))));
            List<String> reasons = new ArrayList<>();
            if (((Number) row.get("status")).intValue() != 1
                    || !Boolean.TRUE.equals(row.get("is_closed"))
                    || Boolean.TRUE.equals(row.get("is_deleted"))) {
                reasons.add("NOT_CLOSED_OR_APPROVED");
            }
            if (((Number) row.get("open_quality_cases")).longValue() > 0) reasons.add("OPEN_QUALITY_CASES");
            if (((Number) row.get("draft_receipts")).longValue() > 0) reasons.add("DRAFT_RECEIPTS");
            if (((Number) row.get("draft_returns")).longValue() > 0) reasons.add("DRAFT_RETURNS");
            if (((Number) row.get("unsettled_rows")).longValue() > 0) reasons.add("UNSETTLED_LEDGER");
            if (ledgerRows == 0) reasons.add("NO_SETTLED_EVIDENCE");
            if (ledgerRows > 0 && finalSettled != null && finalSettled.isAfter(cutoff)) {
                reasons.add("SETTLED_TOO_RECENT");
            }
            if (ledgerRows > 0 && finalSettled == null && ((Number) row.get("unsettled_rows")).longValue() == 0) {
                reasons.add("SETTLED_DATE_MISSING");
            }
            result.add(new Evaluation(orderId, billNo, reasons.isEmpty(), reasons, finalSettled));
        }
        return result;
    }

    /** 单事务一致快照内组装完整对象族（服务端组装, 与业务读侧同一事实表）。 */
    private String assemblePayload(UUID orderId) {
        return jdbc.queryForObject("""
                SELECT jsonb_build_object(
                    'family', 'PURCHASE_ORDER',
                    'policyVersion', %s,
                    'order', to_jsonb(o),
                    'items', (SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.line_no NULLS LAST, i.id), '[]'::jsonb)
                                FROM purchase_order_items i WHERE i.order_id = o.id),
                    'approvalCases', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.created_at, c.id), '[]'::jsonb)
                                FROM procurement_order_approval_cases c
                                WHERE c.order_type = 'PURCHASE' AND c.order_id = o.id),
                    'receipts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                        'head', to_jsonb(r),
                                        'items', (SELECT COALESCE(jsonb_agg(to_jsonb(ri) ORDER BY ri.line_no NULLS LAST, ri.id), '[]'::jsonb)
                                                    FROM purchase_receipt_items ri WHERE ri.receipt_id = r.id))
                                        ORDER BY r.bill_date, r.id), '[]'::jsonb)
                                FROM purchase_receipts r
                                WHERE EXISTS (SELECT 1 FROM purchase_receipt_items ri
                                               WHERE ri.receipt_id = r.id
                                                 AND ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))),
                    'returns', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                        'head', to_jsonb(t),
                                        'items', (SELECT COALESCE(jsonb_agg(to_jsonb(ti) ORDER BY ti.line_no NULLS LAST, ti.id), '[]'::jsonb)
                                                    FROM purchase_return_items ti WHERE ti.return_id = t.id))
                                        ORDER BY t.bill_date, t.id), '[]'::jsonb)
                                FROM purchase_returns t
                                WHERE EXISTS (SELECT 1 FROM purchase_return_items ti
                                               WHERE ti.return_id = t.id
                                                 AND ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))),
                    'ledger', (SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.bill_date, l.id), '[]'::jsonb)
                                FROM ar_ap_ledger l
                                WHERE NOT l.is_deleted AND (
                                    (l.source_doc_type = 'PURCHASE_RECEIPT' AND l.source_doc_id IN
                                        (SELECT DISTINCT ri.receipt_id FROM purchase_receipt_items ri
                                          WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id)))
                                 OR (l.source_doc_type = 'PURCHASE_RETURN' AND l.source_doc_id IN
                                        (SELECT DISTINCT ti.return_id FROM purchase_return_items ti
                                          WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))))),
                    'qualityCases', (SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at, q.id), '[]'::jsonb)
                                FROM procurement_iqc_rejection_cases q
                                WHERE q.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = o.id))
                )::text
                FROM purchase_orders o WHERE o.id = ?
                """.formatted("'" + POLICY_VERSION + "'"), String.class, orderId);
    }

    /** 附件原件引用单独成列：原件字节与权限仍在附件体系, 包只带身份+哈希供核对。 */
    private String attachmentRefsJson(UUID orderId) {
        String refs = jdbc.queryForObject("""
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'attachmentId', a.id,
                        'storageProvider', a.storage_provider,
                        'storageKey', a.storage_key,
                        'storageVersion', a.storage_version,
                        'sha256', a.sha256,
                        'sizeBytes', a.size_bytes,
                        'lifecycleState', a.lifecycle_state) ORDER BY a.created_at, a.id), '[]'::jsonb)::text
                FROM attachments a
                WHERE a.owner_type = 'PURCHASE_ORDER' AND a.owner_id = ?
                """, String.class, orderId);
        return refs == null ? "[]" : refs;
    }

    private Map<String, Object> lineCounts(UUID orderId) {
        Map<String, Object> counts = new LinkedHashMap<>();
        counts.put("items", count("SELECT count(*) FROM purchase_order_items WHERE order_id = ?", orderId));
        counts.put("receipts", count("""
                SELECT count(DISTINCT ri.receipt_id) FROM purchase_receipt_items ri
                WHERE ri.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = ?)
                """, orderId));
        counts.put("returns", count("""
                SELECT count(DISTINCT ti.return_id) FROM purchase_return_items ti
                WHERE ti.order_item_id IN (SELECT oi.id FROM purchase_order_items oi WHERE oi.order_id = ?)
                """, orderId));
        counts.put("attachments", count(
                "SELECT count(*) FROM attachments WHERE owner_type = 'PURCHASE_ORDER' AND owner_id = ?",
                orderId));
        return counts;
    }

    private long count(String sql, UUID orderId) {
        Long value = jdbc.queryForObject(sql, Long.class, orderId);
        return value == null ? 0 : value;
    }

    /** 最近一次 VERIFIED 包（历史读取入口用；HTTP 面由控制器统一授权）。 */
    @Transactional(readOnly = true)
    public Map<String, Object> latestPackage(String objectFamily, UUID objectId) {
        return jdbc.queryForMap("""
                SELECT object_family, object_id, package_version, policy_version,
                       payload::text AS payload, payload_sha256, attachment_refs::text AS attachment_refs,
                       line_counts::text AS line_counts, status, created_at
                FROM business_archive_packages
                WHERE object_family = ? AND object_id = ? AND status = 'VERIFIED'
                ORDER BY package_version DESC
                LIMIT 1
                """, objectFamily, objectId);
    }

    /** 资格登记分页读取（管理端；HTTP 面由控制器统一授权）。 */
    @Transactional(readOnly = true)
    public Map<String, Object> eligibilityPage(String objectFamily, Boolean eligible, int page, int size) {
        int boundedSize = Math.max(1, Math.min(size, 100));
        int boundedPage = Math.max(1, page);
        long offset = ((long) boundedPage - 1L) * boundedSize;
        StringBuilder where = new StringBuilder("WHERE object_family = ?");
        List<Object> args = new ArrayList<>(List.of(objectFamily));
        if (eligible != null) {
            where.append(" AND eligible = ?");
            args.add(eligible);
        }
        Long total = jdbc.queryForObject(
                "SELECT count(*) FROM business_archive_eligibility " + where, Long.class, args.toArray());
        args.add(boundedSize);
        args.add(offset);
        List<Map<String, Object>> items = jdbc.queryForList("""
                SELECT object_family, object_id, evaluated_at, eligible,
                       blocked_reasons::text AS blocked_reasons, final_settled_on,
                       facts::text AS facts
                FROM business_archive_eligibility
                """ + where + " ORDER BY evaluated_at DESC, object_id LIMIT ? OFFSET ?", args.toArray());
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("total", total == null ? 0 : total);
        result.put("items", items);
        return result;
    }

    private String toJson(Object value) {
        try {
            return mapper.writeValueAsString(value);
        } catch (Exception e) {
            throw new IllegalStateException("归档登记序列化失败", e);
        }
    }

    static String sha256(String text) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(
                    digest.digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 不可用", e);
        }
    }

    /** 打包结果: PACKAGED=新包, UNCHANGED=同摘要幂等跳过, SKIPPED_NOT_ELIGIBLE=复核未过。 */
    public record PackageOutcome(
            UUID objectId, String outcome, String payloadSha256, Map<String, Object> lineCounts) {

        public JsonNode toJsonNode(ObjectMapper mapper) {
            return mapper.valueToTree(this);
        }
    }
}
