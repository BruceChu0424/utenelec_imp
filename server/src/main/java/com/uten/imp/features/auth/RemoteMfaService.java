package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RemoteAccessPolicy;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * Server-owned TOTP lifecycle. Factor mutations serialize on the user row. Credential revocation
 * takes refresh-token locks before session locks; rejected OTP attempts commit before being reported.
 */
@Service
public class RemoteMfaService {
    static final Duration ENROLLMENT_TTL = Duration.ofMinutes(10);
    static final Duration LOCK_DURATION = Duration.ofMinutes(15);
    static final int MAX_FAILURES = 5;

    private final NamedParameterJdbcTemplate jdbc;
    private final UserAccountRepository users;
    private final RefreshTokenRepository refreshTokens;
    private final AuthSessionService sessions;
    private final SecretCipher cipher;
    private final RemoteAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final AuditService audit;
    private final TransactionTemplate transaction;

    public RemoteMfaService(NamedParameterJdbcTemplate jdbc, UserAccountRepository users,
                            RefreshTokenRepository refreshTokens, AuthSessionService sessions,
                            SecretCipher cipher, RemoteAccessPolicy access, SecurityContextCurrentUser current,
                            AuditService audit, PlatformTransactionManager transactionManager) {
        this.jdbc = jdbc; this.users = users; this.refreshTokens = refreshTokens; this.sessions = sessions;
        this.cipher = cipher; this.access = access; this.current = current; this.audit = audit;
        this.transaction = new TransactionTemplate(transactionManager);
    }

    public record Status(boolean enabled, boolean pending, Instant pendingExpiresAt, boolean sessionVerified,
                         Instant sessionVerifiedUntil, boolean enrollmentAllowed, boolean remoteRequest) {}
    public record Enrollment(String secret, String otpauthUri, Instant expiresAt) {
        @Override public String toString() { return "Enrollment[credentials=REDACTED]"; }
    }
    public record Verified(Instant verifiedUntil) {}
    public record Revoked(boolean reauthenticationRequired) {}
    private record Attempt<T>(T value, ErrorCode error) {
        static <T> Attempt<T> ok(T value) { return new Attempt<>(value, null); }
        static <T> Attempt<T> denied(ErrorCode error) { return new Attempt<>(null, error); }
        T requireSuccess() { if (error != null) throw new ApiException(error); return value; }
    }
    private record State(String secret, Instant enabledAt, String pendingSecret, UUID pendingSession,
                         Instant pendingExpiresAt, Long lastStep, int failures, Instant lockedUntil) {}

    public Status status() {
        AuthUser principal = staff();
        State state = loadState(principal.getId());
        var fresh = sessions.loadStaff(principal.getId(), principal.getSessionId(), principal.getId());
        AuthSessionService.SessionFacts facts = fresh.map(AuthSessionService.StaffState::session).orElse(null);
        if (facts == null || facts.revokedAt() != null) throw new ApiException(ErrorCode.UNAUTHORIZED);
        Instant verified = facts.mfaVerifiedAt();
        boolean valid = state != null && state.enabledAt() != null && AuthSessionService.isMfaVerified(verified, sessions.now());
        Instant until = valid ? earlier(verified.plus(AuthSessionService.MFA_VALIDITY), facts.absoluteExpiresAt()) : null;
        boolean pending = state != null && principal.getSessionId().equals(state.pendingSession())
                && state.pendingExpiresAt() != null && state.pendingExpiresAt().isAfter(sessions.now());
        return new Status(state != null && state.enabledAt() != null, pending,
                pending ? state.pendingExpiresAt() : null, valid, until,
                !access.isRemoteRequest() && !principal.isMustChangePassword(), access.isRemoteRequest());
    }

    public Enrollment beginEnrollment() {
        AuthUser principal = lanStaff();
        if (!cipher.available()) throw new ApiException(ErrorCode.MFA_UNAVAILABLE);
        return transaction.execute(status -> {
            UserAccount user = lockUser(principal.getId());
            requireCurrentSession(principal);
            State state = lockState(user.getId());
            requireUnlocked(state);
            if (state.enabledAt() != null) throw new ApiException(ErrorCode.CONFLICT, "已绑定动态验证码，请先在公司内网解除原绑定");
            String secret = Totp.newSecret();
            Instant expires = sessions.now().plus(ENROLLMENT_TTL);
            jdbc.update("""
                    UPDATE staff_mfa SET pending_secret_ciphertext=:secret,pending_session_id=:sid,
                        pending_expires_at=:expires,updated_at=:now WHERE user_id=:user
                    """, params(user.getId()).addValue("secret", cipher.encrypt(secret, aad(user.getId(), true)))
                    .addValue("sid", principal.getSessionId()).addValue("expires", ts(expires)));
            audit(user, "mfa_enrollment_started", "success");
            String label = URLEncoder.encode("Uten ERP:" + user.getLoginAccount(), StandardCharsets.UTF_8).replace("+", "%20");
            return new Enrollment(secret, "otpauth://totp/" + label + "?secret=" + secret
                    + "&issuer=Uten%20ERP&algorithm=SHA1&digits=6&period=30", expires);
        });
    }

    public Status confirmEnrollment(String code) {
        AuthUser principal = lanStaff();
        Attempt<Void> result = transaction.execute(status -> {
            UserAccount user = lockUser(principal.getId());
            requireCurrentSession(principal);
            State state = lockState(user.getId());
            if (state.enabledAt() != null) return Attempt.denied(ErrorCode.CONFLICT);
            if (state.pendingSecret() == null || !principal.getSessionId().equals(state.pendingSession())
                    || !state.pendingExpiresAt().isAfter(sessions.now())) return Attempt.denied(ErrorCode.MFA_ENROLLMENT_EXPIRED);
            ErrorCode blocked = locked(state);
            if (blocked != null) return Attempt.denied(blocked);
            String secret = decrypt(state.pendingSecret(), user.getId(), true);
            long step = Totp.matchingStep(secret, code, sessions.now(), null);
            if (step < 0) return Attempt.denied(failure(user, state));
            jdbc.update("""
                    UPDATE staff_mfa SET secret_ciphertext=:secret,enabled_at=:now,
                        pending_secret_ciphertext=NULL,pending_session_id=NULL,pending_expires_at=NULL,
                        last_accepted_step=:step,failed_attempts=0,locked_until=NULL,updated_at=:now WHERE user_id=:user
                    """, params(user.getId()).addValue("secret", cipher.encrypt(secret, aad(user.getId(), false))).addValue("step", step));
            sessions.clearMfaForUser(user.getId());
            sessions.markMfaVerified(principal.getSessionId(), user.getId(), sessions.now());
            audit(user, "mfa_enrolled", "success");
            return Attempt.ok(null);
        });
        result.requireSuccess();
        return status();
    }

    /** Called only after password/account/remote eligibility checks; issuance joins this same transaction. */
    public TokenResponse remoteLogin(UUID userId, String code, Supplier<TokenResponse> issueTokens) {
        Attempt<TokenResponse> result = transaction.execute(status -> {
            UserAccount user = lockUser(userId);
            access.requireStaffAccess(user);
            ErrorCode denied = verifyLocked(user, lockState(userId), code);
            if (denied != null) return Attempt.denied(denied);
            TokenResponse response = issueTokens.get();
            audit(user, "mfa_remote_login_verified", "success");
            return Attempt.ok(response);
        });
        return result.requireSuccess();
    }

    public Verified verifySession(String code) {
        AuthUser principal = staff();
        Attempt<Verified> result = transaction.execute(status -> {
            UserAccount user = lockUser(principal.getId());
            access.requireStaffAccess(user);
            requireCurrentSession(principal);
            ErrorCode denied = verifyLocked(user, lockState(user.getId()), code);
            if (denied != null) return Attempt.denied(denied);
            Instant until = sessions.markMfaVerified(principal.getSessionId(), user.getId(), sessions.now());
            audit(user, "mfa_session_verified", "success");
            return Attempt.ok(new Verified(until));
        });
        return result.requireSuccess();
    }

    public Revoked disable(String code) {
        AuthUser principal = lanStaff();
        Attempt<Revoked> result = transaction.execute(status -> {
            UserAccount user = lockUser(principal.getId());
            // Refresh/logout take token -> session locks. Do not hold the session while
            // waiting to revoke tokens: that would deadlock with an in-flight rotation.
            requireCurrentSessionSnapshot(principal);
            ErrorCode denied = verifyLocked(user, lockState(user.getId()), code);
            if (denied != null) return Attempt.denied(denied);
            refreshTokens.revokeAllByUserId(user.getId());
            // Logout may have won while we waited. A failed locked recheck must throw,
            // rolling back both token revocation and OTP consumption before clearing MFA.
            requireCurrentSession(principal);
            clearFactorAndSessions(user.getId());
            audit(user, "mfa_disabled", "success");
            return Attempt.ok(new Revoked(true));
        });
        return result.requireSuccess();
    }

    public Revoked reset(UUID userId, String reason) {
        AuthUser principal = lanStaff();
        if (!principal.isSuperAdmin() || !principal.getPermissions().contains("authorization:manage")) throw new ApiException(ErrorCode.FORBIDDEN);
        if (reason == null || reason.isBlank() || reason.length() > 256) throw new ApiException(ErrorCode.VALIDATION_FAILED);
        return transaction.execute(status -> {
            users.findByIdForUpdate(userId).filter(u -> !u.isDeleted())
                    .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
            // Do not lock a different administrator's session while holding the target user:
            // two administrators resetting one another must not take opposite lock orders.
            var actor = sessions.loadStaff(principal.getId(), principal.getSessionId(), principal.getId())
                    .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
            if (!actor.superAdmin() || actor.deleted() || !"active".equals(actor.status())
                    || !StaffAuthenticationPolicy.currentEmployee(actor.employeeId(), actor.employeeDeleted(), actor.employeeStatus())
                    || StaffAuthenticationPolicy.temporaryPasswordExpired(actor.mustChangePassword(), actor.tempPasswordExpiresAt()))
                throw new ApiException(ErrorCode.FORBIDDEN);
            if (AuthSessionService.evaluate(actor.session(), AuthSessionService.idleTimeoutMinutes(actor.idleTimeoutRaw()), sessions.now())
                    != AuthSessionService.Verdict.ACTIVE) throw new ApiException(ErrorCode.UNAUTHORIZED);
            lockState(userId);
            refreshTokens.revokeAllByUserId(userId);
            clearFactorAndSessions(userId);
            audit.logCommitted(principal.getId(), principal.getLoginAccount(), "mfa_admin_reset", "users",
                    userId.toString(), "success;reason=" + reason.strip());
            return new Revoked(true);
        });
    }

    /** Never reacquire refresh-token locks here: the caller may already hold a session lock. */
    private void clearFactorAndSessions(UUID userId) {
        jdbc.update("""
                UPDATE staff_mfa SET secret_ciphertext=NULL,enabled_at=NULL,pending_secret_ciphertext=NULL,
                    pending_session_id=NULL,pending_expires_at=NULL,last_accepted_step=NULL,
                    failed_attempts=0,locked_until=NULL,updated_at=:now WHERE user_id=:user
                """, params(userId));
        // A refresh that committed while the bulk token update waited can have inserted
        // a token outside that UPDATE's snapshot. Revoking its shared sid is authoritative.
        sessions.revokeAllForUser(userId, AuthSessionService.REASON_MFA_CHANGED);
        sessions.clearMfaForUser(userId);
    }

    private ErrorCode verifyLocked(UserAccount user, State state, String code) {
        if (state.enabledAt() == null) return ErrorCode.MFA_ENROLLMENT_REQUIRED;
        ErrorCode blocked = locked(state);
        if (blocked != null) return blocked;
        if (code == null || code.isBlank()) return ErrorCode.MFA_REQUIRED;
        String secret = decrypt(state.secret(), user.getId(), false);
        long step = Totp.matchingStep(secret, code, sessions.now(), state.lastStep());
        if (step < 0) return failure(user, state);
        jdbc.update("""
                UPDATE staff_mfa SET last_accepted_step=:step,failed_attempts=0,locked_until=NULL,updated_at=:now
                WHERE user_id=:user
                """, params(user.getId()).addValue("step", step));
        return null;
    }

    private ErrorCode failure(UserAccount user, State state) {
        int attempts = state.lockedUntil() != null && !state.lockedUntil().isAfter(sessions.now()) ? 1 : state.failures() + 1;
        Instant locked = attempts >= MAX_FAILURES ? sessions.now().plus(LOCK_DURATION) : null;
        jdbc.update("UPDATE staff_mfa SET failed_attempts=:attempts,locked_until=:locked,updated_at=:now WHERE user_id=:user",
                params(user.getId()).addValue("attempts", attempts).addValue("locked", ts(locked), java.sql.Types.TIMESTAMP_WITH_TIMEZONE));
        audit(user, locked == null ? "mfa_failed" : "mfa_locked", "failure");
        return locked == null ? ErrorCode.MFA_INVALID : ErrorCode.MFA_LOCKED;
    }

    /** Status projections never initialize a factor row or acquire a write lock. */
    private State loadState(UUID userId) {
        List<State> rows = jdbc.query("SELECT * FROM staff_mfa WHERE user_id=:user", params(userId),
                (rs, n) -> stateRow(rs));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** Factor commands initialize and lock their state after locking the account. */
    private State lockState(UUID userId) {
        jdbc.update("INSERT INTO staff_mfa(user_id) VALUES(:user) ON CONFLICT(user_id) DO NOTHING", params(userId));
        List<State> rows = jdbc.query("SELECT * FROM staff_mfa WHERE user_id=:user FOR UPDATE", params(userId),
                (rs, n) -> stateRow(rs));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private static State stateRow(ResultSet rs) throws SQLException {
        return new State(rs.getString("secret_ciphertext"), instant(rs.getObject("enabled_at", OffsetDateTime.class)),
                rs.getString("pending_secret_ciphertext"), rs.getObject("pending_session_id", UUID.class),
                instant(rs.getObject("pending_expires_at", OffsetDateTime.class)), rs.getObject("last_accepted_step", Long.class),
                rs.getInt("failed_attempts"), instant(rs.getObject("locked_until", OffsetDateTime.class)));
    }

    private UserAccount lockUser(UUID id) {
        UserAccount user = users.findByIdForUpdate(id).filter(u -> !u.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if ("disabled".equals(user.getStatus())) throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        boolean expiredTemporaryLock = "locked".equals(user.getStatus()) && user.getLockedUntil() != null
                && !user.getLockedUntil().toInstant().isAfter(sessions.now());
        if ((!"active".equals(user.getStatus()) && !expiredTemporaryLock)
                || user.getLockedUntil() != null && user.getLockedUntil().toInstant().isAfter(sessions.now()))
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        StaffAuthenticationPolicy.requireCurrentEmployee(users, user);
        StaffAuthenticationPolicy.requireCurrentTemporaryPassword(user);
        return user;
    }

    private void requireCurrentSession(AuthUser user) {
        if (sessions.lockAndEvaluateForRefresh(user.getSessionId(), user.getId(), null) != AuthSessionService.Verdict.ACTIVE)
            throw new ApiException(ErrorCode.UNAUTHORIZED);
    }

    private void requireCurrentSessionSnapshot(AuthUser user) {
        var state = sessions.loadStaff(user.getId(), user.getSessionId(), user.getId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (AuthSessionService.evaluate(state.session(), AuthSessionService.idleTimeoutMinutes(state.idleTimeoutRaw()), sessions.now())
                != AuthSessionService.Verdict.ACTIVE) throw new ApiException(ErrorCode.UNAUTHORIZED);
    }

    private AuthUser staff() {
        AuthUser user = current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getSessionId() == null || user.getImpersonatedBy() != null) throw new ApiException(ErrorCode.FORBIDDEN);
        return user;
    }

    private AuthUser lanStaff() {
        AuthUser user = staff();
        if (access.isRemoteRequest()) throw new ApiException(ErrorCode.FORBIDDEN, "请在公司内网管理动态验证码绑定");
        if (user.isMustChangePassword()) throw new ApiException(ErrorCode.PASSWORD_CHANGE_REQUIRED);
        return user;
    }

    private ErrorCode locked(State state) { return state.lockedUntil() != null && state.lockedUntil().isAfter(sessions.now()) ? ErrorCode.MFA_LOCKED : null; }
    private void requireUnlocked(State state) { if (locked(state) != null) throw new ApiException(ErrorCode.MFA_LOCKED); }
    private String decrypt(String value, UUID user, boolean pending) {
        try { return cipher.decrypt(value, aad(user, pending)); }
        catch (SecretCipher.SecretUnreadableException failure) { throw new ApiException(ErrorCode.MFA_UNAVAILABLE); }
    }
    private static String aad(UUID user, boolean pending) { return "staff_mfa|" + (pending ? "pending_secret" : "secret") + "|" + user; }
    private MapSqlParameterSource params(UUID user) { return new MapSqlParameterSource("user", user).addValue("now", ts(sessions.now())); }
    private void audit(UserAccount user, String action, String result) { audit.logCommitted(user.getId(), user.getLoginAccount(), action, "users", user.getId().toString(), result); }
    private static Instant earlier(Instant a, Instant b) { return a.isBefore(b) ? a : b; }
    private static Instant instant(OffsetDateTime value) { return value == null ? null : value.toInstant(); }
    private static OffsetDateTime ts(Instant value) { return value == null ? null : OffsetDateTime.ofInstant(value, ZoneOffset.UTC); }
}
