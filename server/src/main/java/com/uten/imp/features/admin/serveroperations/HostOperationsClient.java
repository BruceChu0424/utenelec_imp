package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Map;
import java.util.UUID;

/** Fixed, local root-helper RPC. No caller-supplied socket, shell, executable or path. */
public interface HostOperationsClient {
    enum Operation {
        STATUS, CONFIG_READ, CONFIG_SAVE, UPDATE_START, UPDATE_JOB,
        SCHEDULE_PREVIEW, UPDATE_DISPATCH, UPDATE_CANCEL,
        STORAGE_SUMMARY, STORAGE_LIST, STORAGE_PREVIEW_DELETE, STORAGE_DELETE, STORAGE_RESULT;

        public boolean outcomeMayChangeState() {
            return this == CONFIG_SAVE || this == UPDATE_START || this == STORAGE_DELETE
                    || this == UPDATE_DISPATCH || this == UPDATE_CANCEL;
        }
    }

    /** Returns only the response data; safe failures never contain raw RPC bytes. */
    JsonNode call(Operation operation, Map<String, Object> payload, UUID actorId, UUID requestId);
}
