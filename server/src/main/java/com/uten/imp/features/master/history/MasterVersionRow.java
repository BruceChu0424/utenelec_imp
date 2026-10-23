package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.UUID;

/** Trusted server snapshots, never accepted from an HTTP request. */
public record MasterVersionRow(String table, UUID id, JsonNode current, JsonNode target) {}
