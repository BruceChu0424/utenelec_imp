package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.web.context.request.async.DeferredResult;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** One bounded JSON wait per client; no request thread or database connection is held. */
@Service
@Slf4j
public class SessionWatchService {
    static final long WAIT_MILLIS = 25_000L;
    static final int MAX_WAITERS = 4096;
    static final int MAX_PER_SESSION = 8;
    private final AuthSessionService sessions;
    private final Map<UUID, List<Waiter>> waiting = new HashMap<>();
    private int waiterCount;

    public SessionWatchService(AuthSessionService sessions) {
        this.sessions = sessions;
    }

    public record Response(String status, String code, String message) {
        static Response active() { return new Response("active", null, null); }
        static Response ended(AuthSessionService.RefreshVerdict verdict) {
            return verdict != null && verdict.replacedByLogin()
                    ? new Response("replaced", "SESSION_REPLACED", verdict.replacedNotice())
                    : new Response("expired", "UNAUTHORIZED", "登录已失效，请重新登录");
        }
    }

    private record Waiter(UUID sid, UUID owner, DeferredResult<Response> result) { }

    public DeferredResult<Response> watch(UUID sid, UUID owner) {
        if (sid == null || owner == null) throw new ApiException(ErrorCode.UNAUTHORIZED);
        DeferredResult<Response> result = new DeferredResult<>(WAIT_MILLIS, Response.active());
        Waiter waiter = new Waiter(sid, owner, result);
        synchronized (waiting) {
            List<Waiter> current = waiting.get(sid);
            if (waiterCount >= MAX_WAITERS || (current != null && current.size() >= MAX_PER_SESSION)) {
                throw new ApiException(ErrorCode.RATE_LIMITED);
            }
            waiting.computeIfAbsent(sid, ignored -> new ArrayList<>()).add(waiter);
            waiterCount++;
        }
        result.onCompletion(() -> remove(waiter));
        result.onError(ignored -> remove(waiter));
        result.onTimeout(() -> remove(waiter));
        try {
            // Register first, then read: replacement between JWT verification and
            // registration cannot disappear into the gap between two requests.
            completeIfEnded(waiter, sessions.evaluateStaffWatches(Map.of(sid, owner)).get(sid));
        } catch (RuntimeException failure) {
            remove(waiter);
            throw failure;
        }
        return result;
    }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT, fallbackExecution = true)
    public void replaced(AuthSessionService.ReplacedSessions event) {
        Response response = Response.ended(new AuthSessionService.RefreshVerdict(
                AuthSessionService.Verdict.REVOKED,
                AuthSessionService.REASON_REPLACED_BY_LOGIN, event.device()));
        for (UUID sid : event.sessionIds()) {
            for (Waiter waiter : snapshot(sid)) finish(waiter, response);
        }
    }

    /** Also observes revocations committed by another server process and idle expiry. */
    @Scheduled(fixedDelay = 2000L)
    public void reconcile() {
        List<Waiter> snapshot;
        synchronized (waiting) {
            snapshot = waiting.values().stream().flatMap(List::stream).toList();
        }
        if (snapshot.isEmpty()) return;
        // Keep one bounded SQL statement per 256 current sessions, rather than
        // one database read per connected client or a connection per waiter.
        Map<UUID, UUID> owners = new HashMap<>();
        for (Waiter waiter : snapshot) owners.put(waiter.sid(), waiter.owner());
        List<UUID> ids = new ArrayList<>(owners.keySet());
        try {
            for (int start = 0; start < ids.size(); start += 256) {
                Map<UUID, UUID> batch = new HashMap<>();
                for (UUID sid : ids.subList(start, Math.min(start + 256, ids.size()))) {
                    batch.put(sid, owners.get(sid));
                }
                Map<UUID, AuthSessionService.RefreshVerdict> verdicts = sessions.evaluateStaffWatches(batch);
                for (Waiter waiter : snapshot) {
                    if (batch.containsKey(waiter.sid())) completeIfEnded(waiter, verdicts.get(waiter.sid()));
                }
            }
        } catch (RuntimeException failure) {
            // Availability uncertainty is never authority to log someone out.
            log.warn("Session watch reconciliation unavailable: {}", failure.getClass().getSimpleName());
        }
    }

    private void completeIfEnded(Waiter waiter, AuthSessionService.RefreshVerdict verdict) {
        if (verdict == null || verdict.verdict() != AuthSessionService.Verdict.ACTIVE) {
            finish(waiter, Response.ended(verdict));
        }
    }

    private void finish(Waiter waiter, Response response) {
        remove(waiter);
        try {
            waiter.result().setResult(response);
        } catch (RuntimeException disconnected) {
            // A disconnected old client must not change the committed login's result.
            log.debug("Session watch result receiver unavailable: {}", disconnected.getClass().getSimpleName());
        }
    }

    private List<Waiter> snapshot(UUID sid) {
        synchronized (waiting) {
            return List.copyOf(waiting.getOrDefault(sid, List.of()));
        }
    }

    private void remove(Waiter waiter) {
        synchronized (waiting) {
            List<Waiter> current = waiting.get(waiter.sid());
            if (current != null && current.remove(waiter)) {
                waiterCount--;
                if (current.isEmpty()) waiting.remove(waiter.sid());
            }
        }
    }

    int waitingCount() {
        synchronized (waiting) { return waiterCount; }
    }
}
