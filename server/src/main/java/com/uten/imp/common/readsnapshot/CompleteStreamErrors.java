package com.uten.imp.common.readsnapshot;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.slf4j.Logger;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Error frames of the complete NDJSON streams (master summaries, instant
 * inventory). One helper owns the failure-to-code mapping, the anonymous
 * correlation ref and the server log line that carries it, so a user report
 * quoting the ref locates this exact failure in the server log and in the
 * client's diagnostic record. Only the mapped code, the default or business
 * message and the ref are framed or logged — never row data, filters or
 * account identity.
 */
public final class CompleteStreamErrors {
    private CompleteStreamErrors() {}

    public static ErrorCode codeOf(RuntimeException failure) {
        if (failure instanceof ApiException api) return api.getCode();
        if (failure instanceof org.springframework.security.access.AccessDeniedException)
            return ErrorCode.FORBIDDEN;
        if (failure instanceof org.springframework.transaction.TransactionTimedOutException
                || failure instanceof java.util.concurrent.CancellationException)
            return ErrorCode.PRIMARY_UNAVAILABLE;
        return ErrorCode.INTERNAL;
    }

    /**
     * Logs the failure with its ref (full stack only for INTERNAL) and returns
     * the error frame: type/code/message plus details.correlation, which the
     * client keeps on the exception and shows next to the message. Additive
     * frame field: older readers ignore it.
     */
    public static Map<String, Object> errorFrame(Logger log, String source, RuntimeException failure) {
        ErrorCode code = codeOf(failure);
        String correlation = newRef();
        String message = failure instanceof ApiException api ? api.getMessage() : code.getDefaultMessage();
        if (code == ErrorCode.INTERNAL)
            log.error("Complete stream read failed ref={} source={}", correlation, source, failure);
        else
            log.warn("Complete stream read failed ref={} source={} code={}", correlation, source, code);
        return Map.of("type", "error", "code", code.name(), "message", message,
                "details", Map.of("correlation", correlation));
    }

    private static String newRef() {
        String alphabet = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        StringBuilder ref = new StringBuilder(6);
        for (int index = 0; index < 6; index++)
            ref.append(alphabet.charAt(ThreadLocalRandom.current().nextInt(alphabet.length())));
        return ref.toString();
    }
}
