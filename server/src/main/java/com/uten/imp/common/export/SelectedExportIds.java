package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.json.JsonMapper;
import java.util.List;
import java.util.UUID;

/** Explicit selected-row identities; malformed or empty selection never means export everything. */
public final class SelectedExportIds {
    private static final com.fasterxml.jackson.databind.ObjectMapper JSON = JsonMapper.builder().build();

    private SelectedExportIds() { }

    /** null means all filtered rows; every supplied array must contain canonical UUIDs. */
    public static List<UUID> parse(String input) {
        return MasterExportSelection.parse(input, JSON);
    }
}
