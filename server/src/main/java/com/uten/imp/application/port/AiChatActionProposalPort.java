package com.uten.imp.application.port;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * ADR-150: one-time confirmation cards for actions suggested in the AI assistant.
 *
 * <p>A proposal is not authority. It records a server-rendered summary and the exact validated
 * arguments for the current principal, valid for at most ten minutes. The user's explicit
 * confirmation consumes it once (database guarded). Execution still uses the page's own button
 * path (CLIENT) or the original business endpoint (SERVER), with the normal permission, step-up,
 * version and state checks. Identity changes (auth version, global authorization epoch or
 * department membership) void an unconfirmed proposal.
 */
public interface AiChatActionProposalPort {
    String PAGE_ACTION = "PAGE_ACTION";
    String OPEN_GUIDED_FORM = "OPEN_GUIDED_FORM";
    String PERMISSION_GRANT = "PERMISSION_GRANT";

    /**
     * @param actionType     PAGE_ACTION, OPEN_GUIDED_FORM or PERMISSION_GRANT
     * @param handler        client handler name (page action name) or the action type for server actions
     * @param execution      CLIENT (page handler after confirm) or SERVER (dedicated business endpoint)
     * @param title          card title, at most 80 characters
     * @param summaryLines   server-rendered lines shown on the card, 1..16 lines
     * @param risk           LOW, MEDIUM or HIGH
     * @param riskNote       optional plain-language risk hint
     * @param requiresStepUp only for SERVER actions whose endpoint requires password confirmation
     * @param route          page route the action belongs to (CLIENT actions), otherwise null
     * @param targetType     PAGE, USER or AI_JOB
     * @param targetRef      target identity (route, user id or job id)
     * @param targetVersion  optional optimistic version of the target captured at proposal time
     * @param args           validated arguments returned unchanged on confirmation
     * @param sourceJobId    AI job that produced the proposal
     */
    record Draft(String actionType, String handler, String execution, String title, List<String> summaryLines,
                 String risk, String riskNote, boolean requiresStepUp, String route, String targetType,
                 String targetRef, Long targetVersion, Map<String, Object> args, UUID sourceJobId) {
    }

    /** A server action consumed inside the caller's transaction. */
    record Consumed(UUID id, String actionType, String targetRef, Long targetVersion, Map<String, Object> args) {
    }

    /** Persists a PROPOSED row for the current chat principal in its own transaction and returns the public card. */
    Map<String, Object> propose(Draft draft);

    /**
     * Locks and consumes a SERVER action once, inside the caller's transaction. Throws 404 for an
     * unknown or foreign id and 409 (errorCode AI_ACTION_*) for an expired, handled or identity-changed one.
     */
    Consumed consumeServerAction(UUID id, String actionType);

    /** Records the successful outcome of a consumed server action inside the caller's transaction. */
    void completeServerAction(UUID id, String message);

    /**
     * Records a failed server execution in a new transaction (the business transaction has rolled back).
     * A proposal that was never consumed stays as it is when the failure was an expiry or a repeated click.
     */
    void failServerAction(UUID id, String errorCode, String message);
}
