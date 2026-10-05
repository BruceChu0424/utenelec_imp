package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.uten.imp.application.port.AiChatActionProposalPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * ADR-150 one-time action proposals. The table trigger is the last line of defence; every state
 * change here is a conditional UPDATE so a double click, a replay or a late request changes nothing.
 */
@Service
public class AiChatActionProposalService implements AiChatActionProposalPort {
    public static final long TTL_SECONDS = 600;
    private static final Set<String> TYPES = Set.of(PAGE_ACTION, OPEN_GUIDED_FORM, PERMISSION_GRANT);
    private static final Set<String> RISKS = Set.of("LOW", "MEDIUM", "HIGH");
    private static final Pattern HANDLER = Pattern.compile("[A-Za-z][A-Za-z0-9_]{0,47}");
    private static final Pattern ROUTE = Pattern.compile("/[A-Za-z0-9/_-]*");
    private static final String COLUMNS = """
            id, actor_user_id, actor_auth_version, authorization_epoch, membership_hash, action_type, handler,
            execution, route, target_type, target_ref, target_version, args::text AS args, title, summary::text AS summary,
            risk, risk_note, requires_step_up, status, outcome, outcome_message, issued_at, expires_at,
            confirmed_at, finished_at, (expires_at <= now()) AS expired
            """;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final AiChatAccessPolicy access;
    private final AiChatEvidence evidence;
    private final AuditService audit;
    private final TransactionTemplate newTx;
    private final TransactionTemplate tx;

    public AiChatActionProposalService(JdbcTemplate jdbc, ObjectMapper json, AiChatAccessPolicy access,
                                       AiChatEvidence evidence, AuditService audit, PlatformTransactionManager transactions) {
        this.jdbc = jdbc; this.json = json; this.access = access; this.evidence = evidence; this.audit = audit;
        this.newTx = new TransactionTemplate(transactions);
        this.newTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.newTx.setTimeout(15);
        this.tx = new TransactionTemplate(transactions);
        this.tx.setTimeout(15);
    }

    record Row(UUID id, UUID actor, long authVersion, long epoch, String membershipHash, String actionType,
               String handler, String execution, String route, String targetType, String targetRef, Long targetVersion,
               Map<String, Object> args, String title, List<String> summary, String risk, String riskNote,
               boolean requiresStepUp, String status, String outcome, String outcomeMessage, Instant issuedAt,
               Instant expiresAt, Instant confirmedAt, Instant finishedAt, boolean expired) {}

    /** Identity snapshot of the current chat principal. */
    record Stamp(UUID actor, String account, long authVersion, long epoch, String membershipHash) {}

    @Override
    public Map<String, Object> propose(Draft draft) {
        validate(draft);
        Stamp stamp = stamp();
        UUID id = UUID.randomUUID();
        Map<String, Object> args = draft.args() == null ? Map.of() : draft.args();
        String argsJson = canonical(args);
        if (argsJson.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 4096) throw invalid("操作参数太长");
        String summaryJson = write(List.copyOf(draft.summaryLines()));
        newTx.executeWithoutResult(status -> {
            jdbc.update("""
                    INSERT INTO ai_chat_action_proposals(id, actor_user_id, actor_auth_version, authorization_epoch,
                        membership_hash, source_job_id, action_type, handler, execution, route, target_type, target_ref,
                        target_version, args, args_hash, title, summary, risk, risk_note, requires_step_up,
                        issued_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, (SELECT id FROM ai_jobs WHERE id = ?), ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?,
                        ?::jsonb, ?, ?, ?, now(), now() + make_interval(secs => ?))
                    """, id, stamp.actor(), stamp.authVersion(), stamp.epoch(), stamp.membershipHash(), draft.sourceJobId(),
                    draft.actionType(), draft.handler(), draft.execution(), draft.route(), draft.targetType(),
                    draft.targetRef(), draft.targetVersion(), argsJson, sha256Hex(argsJson), draft.title().strip(),
                    summaryJson, draft.risk(), blankToNull(draft.riskNote()), draft.requiresStepUp(), TTL_SECONDS);
            audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.propose", "ai_chat_action_proposal",
                    id.toString(), truncate(draft.actionType() + " " + draft.handler() + " " + draft.title(), 480));
        });
        return card(load(id, stamp.actor()).orElseThrow(), stamp);
    }

    /** Current card state for the owner, or 404. */
    @Transactional(readOnly = true)
    public Map<String, Object> view(UUID id) {
        Stamp stamp = stamp();
        return card(load(id, stamp.actor()).orElseThrow(AiChatActionProposalService::notFound), stamp);
    }

    /**
     * Client-executed action: consume once and return the exact stored arguments. The caller then runs the
     * page handler (same code path as the page button) and reports the outcome with {@link #receipt}.
     */
    public Map<String, Object> confirmClient(UUID id) {
        Stamp stamp = stamp();
        Decision decision = tx.execute(status -> {
            Row row = lock(id, stamp.actor()).orElseThrow(AiChatActionProposalService::notFound);
            if (!"CLIENT".equals(row.execution()))
                return Decision.reject(row, "AI_ACTION_SERVER_ONLY", "这项操作要在确认卡上验证身份后执行，请点卡片上的确认按钮。");
            String problem = openProblem(row, stamp);
            if (problem != null) return voidRow(row, stamp, problem);
            jdbc.update("""
                    UPDATE ai_chat_action_proposals SET status = 'CONFIRMED', confirmed_at = now()
                    WHERE id = ? AND actor_user_id = ? AND status = 'PROPOSED' AND expires_at > now()
                    """, id, stamp.actor());
            audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.confirm", "ai_chat_action_proposal",
                    id.toString(), truncate(row.handler() + " " + row.title(), 480));
            return Decision.accept(load(id, stamp.actor()).orElseThrow());
        });
        Objects.requireNonNull(decision);
        if (decision.code() != null) throw conflict(decision.code(), decision.message());
        Map<String, Object> result = card(decision.row(), stamp);
        result.put("args", decision.row().args());
        return result;
    }

    /** Cancels an unconfirmed proposal; repeating a cancel is harmless. */
    public Map<String, Object> cancel(UUID id) {
        Stamp stamp = stamp();
        Row row = tx.execute(status -> {
            Row current = lock(id, stamp.actor()).orElseThrow(AiChatActionProposalService::notFound);
            if (!"PROPOSED".equals(current.status())) return current;
            jdbc.update("""
                    UPDATE ai_chat_action_proposals SET status = 'CANCELLED', finished_at = now()
                    WHERE id = ? AND actor_user_id = ? AND status = 'PROPOSED'
                    """, id, stamp.actor());
            audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.cancel", "ai_chat_action_proposal",
                    id.toString(), truncate(current.title(), 480));
            return load(id, stamp.actor()).orElseThrow();
        });
        return card(Objects.requireNonNull(row), stamp);
    }

    /** The single execution receipt of a confirmed client action. Repeating the same receipt is harmless. */
    public Map<String, Object> receipt(UUID id, String outcome, String message) {
        if (!Set.of("SUCCEEDED", "FAILED").contains(outcome)) throw invalid("执行结果只能是成功或失败");
        String note = message == null ? null : truncate(clean(message), 500);
        Stamp stamp = stamp();
        Decision decision = tx.execute(status -> {
            Row row = lock(id, stamp.actor()).orElseThrow(AiChatActionProposalService::notFound);
            if (!"CLIENT".equals(row.execution()))
                return Decision.reject(row, "AI_ACTION_SERVER_ONLY", "这项操作由服务端记录执行结果。");
            if (row.finishedAt() != null && outcome.equals(row.outcome())) return Decision.accept(row);
            if (!"CONFIRMED".equals(row.status()) || row.finishedAt() != null)
                return Decision.reject(row, "AI_ACTION_NOT_CONFIRMED", "这张确认卡还没有确认或已经记录过结果。");
            jdbc.update("""
                    UPDATE ai_chat_action_proposals
                    SET status = CASE WHEN ? = 'FAILED' THEN 'FAILED' ELSE 'CONFIRMED' END,
                        outcome = ?, outcome_message = ?, finished_at = now()
                    WHERE id = ? AND actor_user_id = ? AND status = 'CONFIRMED' AND finished_at IS NULL
                    """, outcome, outcome, note, id, stamp.actor());
            audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.receipt", "ai_chat_action_proposal",
                    id.toString(), truncate(outcome + " " + row.handler() + (note == null ? "" : " " + note), 480));
            return Decision.accept(load(id, stamp.actor()).orElseThrow());
        });
        Objects.requireNonNull(decision);
        if (decision.code() != null) throw conflict(decision.code(), decision.message());
        return card(decision.row(), stamp);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public Consumed consumeServerAction(UUID id, String actionType) {
        Stamp stamp = stamp();
        Row row = lock(id, stamp.actor()).orElseThrow(AiChatActionProposalService::notFound);
        if (!actionType.equals(row.actionType()) || !"SERVER".equals(row.execution())) throw notFound();
        String problem = openProblem(row, stamp);
        if (problem != null) throw conflict(problem, message(problem));
        jdbc.update("""
                UPDATE ai_chat_action_proposals SET status = 'CONFIRMED', confirmed_at = now()
                WHERE id = ? AND actor_user_id = ? AND status = 'PROPOSED' AND expires_at > now()
                """, id, stamp.actor());
        audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.confirm", "ai_chat_action_proposal",
                id.toString(), truncate(row.handler() + " " + row.title(), 480));
        return new Consumed(row.id(), row.actionType(), row.targetRef(), row.targetVersion(), row.args());
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void completeServerAction(UUID id, String message) {
        Stamp stamp = stamp();
        int changed = jdbc.update("""
                UPDATE ai_chat_action_proposals SET outcome = 'SUCCEEDED', outcome_message = ?, finished_at = now()
                WHERE id = ? AND actor_user_id = ? AND status = 'CONFIRMED' AND finished_at IS NULL
                """, message == null ? null : truncate(clean(message), 500), id, stamp.actor());
        if (changed != 1) throw conflict("AI_ACTION_NOT_CONFIRMED", "这张确认卡还没有确认或已经记录过结果。");
    }

    @Override
    public void failServerAction(UUID id, String errorCode, String message) {
        Stamp stamp;
        try { stamp = stamp(); }
        catch (ApiException noLongerChatting) { return; } // the original rejection is reported unchanged
        // Expired, repeated or identity-changed proposals keep their state; their read view already says why.
        if (Set.of("AI_ACTION_EXPIRED", "AI_ACTION_HANDLED", "AI_ACTION_AUTH_CHANGED").contains(errorCode)) return;
        newTx.executeWithoutResult(status -> {
            int changed = jdbc.update("""
                    UPDATE ai_chat_action_proposals SET status = 'FAILED', outcome = 'FAILED', outcome_message = ?,
                        finished_at = now()
                    WHERE id = ? AND actor_user_id = ? AND status = 'PROPOSED' AND execution = 'SERVER'
                    """, message == null ? null : truncate(clean(message), 500), id, stamp.actor());
            if (changed == 1) audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.failed",
                    "ai_chat_action_proposal", id.toString(), truncate(message == null ? "FAILED" : clean(message), 480));
        });
    }

    /**
     * Reader filter for stored chat/document results: keeps only the owner's cards and refreshes their
     * state from the database. Unknown, foreign or purged proposals disappear from the history.
     */
    public List<Map<String, Object>> refreshCards(Object raw) {
        if (!(raw instanceof List<?> values) || values.isEmpty()) return List.of();
        return refreshCards(raw, evidence.stamp());
    }

    /**
     * Same as {@link #refreshCards(Object)} with the reader's identity stamp already computed (ADR-152: a
     * conversation restore or memory read checks many turns with one stamp). One query per call.
     */
    List<Map<String, Object>> refreshCards(Object raw, Map<String, Object> evidenceStamp) {
        if (!(raw instanceof List<?> values) || values.isEmpty()) return List.of();
        List<UUID> ids = new ArrayList<>();
        for (Object value : values.stream().limit(8).toList()) {
            if (!(value instanceof Map<?, ?> card) || !"CONFIRM_ACTION".equals(card.get("type"))
                    || !(card.get("proposalId") instanceof String text)) continue;
            try { ids.add(UUID.fromString(text)); } catch (IllegalArgumentException malformed) { /* not a card */ }
        }
        if (ids.isEmpty()) return List.of();
        Stamp stamp = stamp(evidenceStamp);
        List<Object> params = new ArrayList<>(ids);
        params.add(stamp.actor());
        Map<UUID, Row> rows = new java.util.HashMap<>();
        jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_action_proposals WHERE id IN ("
                        + String.join(",", java.util.Collections.nCopies(ids.size(), "?")) + ") AND actor_user_id = ?",
                this::row, params.toArray()).forEach(row -> rows.put(row.id(), row));
        List<Map<String, Object>> result = new ArrayList<>();
        for (UUID id : ids) {
            Row row = rows.get(id);
            if (row != null) result.add(card(row, stamp));
        }
        return List.copyOf(result);
    }

    /** Housekeeping: close open proposals whose time window passed and drop old rows. */
    public int expireAndPurge(int retentionDays) {
        return tx.execute(status -> jdbc.update("""
                UPDATE ai_chat_action_proposals SET status = 'EXPIRED', finished_at = now()
                WHERE status = 'PROPOSED' AND expires_at <= now()
                """) + jdbc.update("""
                DELETE FROM ai_chat_action_proposals WHERE issued_at < now() - make_interval(days => ?)
                """, Math.max(1, retentionDays)));
    }

    private record Decision(Row row, String code, String message) {
        static Decision accept(Row row) { return new Decision(row, null, null); }
        static Decision reject(Row row, String code, String message) { return new Decision(row, code, message); }
    }

    /** Persists why an open proposal can no longer be confirmed, then reports it. */
    private Decision voidRow(Row row, Stamp stamp, String problem) {
        if ("AI_ACTION_EXPIRED".equals(problem) && "PROPOSED".equals(row.status())) {
            jdbc.update("UPDATE ai_chat_action_proposals SET status = 'EXPIRED', finished_at = now() WHERE id = ? AND status = 'PROPOSED'",
                    row.id());
        } else if ("AI_ACTION_AUTH_CHANGED".equals(problem) && "PROPOSED".equals(row.status())) {
            jdbc.update("""
                    UPDATE ai_chat_action_proposals SET status = 'CANCELLED', outcome = 'AUTH_CHANGED', finished_at = now()
                    WHERE id = ? AND status = 'PROPOSED'
                    """, row.id());
            audit.logCommitted(stamp.actor(), stamp.account(), "ai_action.void", "ai_chat_action_proposal",
                    row.id().toString(), "AUTH_CHANGED");
        }
        return Decision.reject(row, problem, message(problem));
    }

    /** Null when the proposal can still be confirmed by this principal. */
    private static String openProblem(Row row, Stamp stamp) {
        if (!"PROPOSED".equals(row.status())) return "AI_ACTION_HANDLED";
        if (row.expired()) return "AI_ACTION_EXPIRED";
        if (row.authVersion() != stamp.authVersion() || row.epoch() != stamp.epoch()
                || !row.membershipHash().equals(stamp.membershipHash())) return "AI_ACTION_AUTH_CHANGED";
        return null;
    }

    private static String message(String code) {
        return switch (code) {
            case "AI_ACTION_EXPIRED" -> "这张确认卡已过期，请重新提问生成新的确认卡。";
            case "AI_ACTION_AUTH_CHANGED" -> "你的账号权限或部门有变化，这张确认卡已作废，请重新提问。";
            default -> "这张确认卡已经处理过，不能再次确认。";
        };
    }

    /** Public card; status is the effective state (an expired or identity-changed open proposal is not open). */
    Map<String, Object> card(Row row, Stamp stamp) {
        String status = row.status();
        String outcome = row.outcome();
        if ("PROPOSED".equals(status)) {
            String problem = openProblem(row, stamp);
            if ("AI_ACTION_EXPIRED".equals(problem)) status = "EXPIRED";
            else if ("AI_ACTION_AUTH_CHANGED".equals(problem)) { status = "CANCELLED"; outcome = "AUTH_CHANGED"; }
        }
        Map<String, Object> card = new LinkedHashMap<>();
        card.put("type", "CONFIRM_ACTION");
        card.put("proposalId", row.id().toString());
        card.put("actionType", row.actionType());
        card.put("handler", row.handler());
        card.put("execution", row.execution());
        card.put("title", row.title());
        card.put("summaryLines", row.summary());
        card.put("risk", row.risk());
        if (row.riskNote() != null) card.put("riskNote", row.riskNote());
        card.put("requiresStepUp", row.requiresStepUp());
        if (row.route() != null) card.put("route", row.route());
        if ("CLIENT".equals(row.execution())) card.put("args", row.args());
        card.put("issuedAt", row.issuedAt().toString());
        card.put("expiresAt", row.expiresAt().toString());
        card.put("status", status);
        if (outcome != null) card.put("outcome", outcome);
        if (row.outcomeMessage() != null) card.put("outcomeMessage", row.outcomeMessage());
        return card;
    }

    Stamp stamp() {
        return stamp(evidence.stamp());
    }

    private Stamp stamp(Map<String, Object> values) {
        AuthUser actor = access.requireChat();
        return new Stamp(actor.getId(), actor.getUsername(), Long.parseLong(String.valueOf(values.get("authVersion"))),
                Long.parseLong(String.valueOf(values.get("epoch"))),
                sha256Hex(String.valueOf(values.get("memberships"))));
    }

    private Optional<Row> load(UUID id, UUID actor) {
        return jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_action_proposals WHERE id = ? AND actor_user_id = ?",
                this::row, id, actor).stream().findFirst();
    }

    private Optional<Row> lock(UUID id, UUID actor) {
        return jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_action_proposals WHERE id = ? AND actor_user_id = ? FOR UPDATE",
                this::row, id, actor).stream().findFirst();
    }

    private Row row(ResultSet rs, int index) throws SQLException {
        try {
            Map<String, Object> args = json.readValue(rs.getString("args"), new TypeReference<>() {});
            List<String> summary = json.readValue(rs.getString("summary"), new TypeReference<>() {});
            long version = rs.getLong("target_version");
            return new Row(rs.getObject("id", UUID.class), rs.getObject("actor_user_id", UUID.class),
                    rs.getLong("actor_auth_version"), rs.getLong("authorization_epoch"), rs.getString("membership_hash"),
                    rs.getString("action_type"), rs.getString("handler"), rs.getString("execution"), rs.getString("route"),
                    rs.getString("target_type"), rs.getString("target_ref"), rs.wasNull() ? null : version, args,
                    rs.getString("title"), summary, rs.getString("risk"), rs.getString("risk_note"),
                    rs.getBoolean("requires_step_up"), rs.getString("status"), rs.getString("outcome"),
                    rs.getString("outcome_message"), instant(rs.getTimestamp("issued_at")),
                    instant(rs.getTimestamp("expires_at")), instant(rs.getTimestamp("confirmed_at")),
                    instant(rs.getTimestamp("finished_at")), rs.getBoolean("expired"));
        } catch (JsonProcessingException corrupt) {
            throw new SQLException("Corrupt AI action proposal", corrupt);
        }
    }

    private void validate(Draft draft) {
        if (draft == null || !TYPES.contains(draft.actionType()) || draft.handler() == null
                || !HANDLER.matcher(draft.handler()).matches() || !Set.of("CLIENT", "SERVER").contains(draft.execution())
                || draft.title() == null || draft.title().isBlank() || draft.title().strip().length() > 80
                || draft.summaryLines() == null || draft.summaryLines().isEmpty() || draft.summaryLines().size() > 16
                || draft.summaryLines().stream().anyMatch(line -> line == null || line.isBlank() || line.length() > 240)
                || !RISKS.contains(draft.risk()) || (draft.riskNote() != null && draft.riskNote().length() > 200)
                || (draft.requiresStepUp() && !"SERVER".equals(draft.execution()))
                || (draft.route() != null && (draft.route().length() > 240 || !ROUTE.matcher(draft.route()).matches()
                        || draft.route().contains("//")))
                || !Set.of("PAGE", "USER", "AI_JOB").contains(draft.targetType())
                || (draft.targetRef() != null && draft.targetRef().length() > 240)
                // ADR-153: nothing on a system administration page is ever done through the assistant.
                || (PAGE_ACTION.equals(draft.actionType()) && AiChatPageSnapshot.protectedPage(draft.route()))) {
            throw new IllegalArgumentException("Invalid AI action proposal draft");
        }
    }

    private String canonical(Map<String, Object> args) {
        try {
            return json.writer().with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writeValueAsString(args);
        } catch (JsonProcessingException impossible) { throw invalid("操作参数无法记录"); }
    }

    private String write(Object value) {
        try { return json.writeValueAsString(value); }
        catch (JsonProcessingException impossible) { throw invalid("确认卡内容无法记录"); }
    }

    static String sha256Hex(String value) {
        try {
            return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        } catch (java.security.NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    private static Instant instant(Timestamp value) { return value == null ? null : value.toInstant(); }
    private static String blankToNull(String value) { return value == null || value.isBlank() ? null : value.strip(); }
    private static String clean(String value) { return value.replaceAll("[\\p{Cc}\\p{Cf}]+", " ").strip(); }
    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) return value;
        int end = Character.isHighSurrogate(value.charAt(max - 1)) ? max - 1 : max;
        return value.substring(0, end);
    }
    private static ApiException notFound() { return new ApiException(ErrorCode.NOT_FOUND, "确认卡不存在或已失效，请重新提问。"); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
    static ApiException conflict(String code, String message) {
        return new ApiException(ErrorCode.CONFLICT, message, List.of(new ApiError.FieldError("errorCode", code)));
    }
}
