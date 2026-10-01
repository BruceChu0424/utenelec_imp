package com.uten.imp.common.platformcolumns;

import java.util.List;
import java.util.UUID;

public final class PlatformColumnContracts {
    private PlatformColumnContracts() { }
    public record Operand(UUID columnId, String fact, String constant) { }
    public record Step(String operation, Operand operand) { }
    public record Formula(Operand base, List<Step> steps) { }
    public record CreateDefinition(String name, String type, boolean priceProtected, Formula formula) { }
    public record Definition(UUID id, String scope, String name, String type, boolean priceProtected,
                             Formula formula, long usageCount, long personalUsageCount) { }
    public record Scope(String scope, String label, boolean canWrite, boolean priceVisible, boolean supportsValues,
                        List<PlatformColumnResourceAdapter.FactDefinition> facts, boolean canDefine, boolean personalDefinitions, boolean canCreate) { }
    public record BatchRead(List<UUID> recordIds, List<UUID> columnIds) { }
    public record CellInput(UUID columnId, String value) { }
    public record Write(long expectedVersion, List<CellInput> cells) { }
    public record Cell(UUID columnId, String value, Definition definition, boolean masked, boolean persisted, String error) { }
    public record Row(UUID recordId, long version, boolean canWrite, List<Cell> cells) { }
    public record HistoryRow(long id,UUID recordId,long version,java.time.Instant changedAt,UUID changedBy,String changedByName,
                             String operation,Row row,boolean historyReadOnly){}
}
