package com.uten.imp.common.delivery;

import java.util.List;
import java.util.UUID;

/** Versioned order intent only. Quantities, goods, units and prices never come from this contract. */
public record DeliveryPlan(Integer version, Mode mode, Packaging packaging,
        List<NodeMode> nodeModes, List<Process> processes, String bomFingerprint) {
    public enum Mode { ASSEMBLED, BOM }
    public enum Packaging { ORIGINAL, BULK, PENDING }
    public enum NodeDelivery { WHOLE, CHILDREN }
    public enum Operation { LASER }
    public record NodeMode(List<UUID> path, NodeDelivery mode) {
        public NodeMode { path = path == null ? List.of() : List.copyOf(path); }
    }
    public record Process(List<UUID> path, Operation operation, Boolean required) {
        public Process { path = path == null ? List.of() : List.copyOf(path); }
    }
    public DeliveryPlan {
        nodeModes = nodeModes == null ? List.of() : List.copyOf(nodeModes);
        processes = processes == null ? List.of() : List.copyOf(processes);
    }
    public static DeliveryPlan assembled() {
        return new DeliveryPlan(1, Mode.ASSEMBLED, Packaging.ORIGINAL, List.of(), List.of(), null);
    }
    @com.fasterxml.jackson.annotation.JsonIgnore
    public boolean isBom() { return mode == Mode.BOM; }
    @com.fasterxml.jackson.annotation.JsonIgnore
    public boolean requiresPhysicalFulfillment() {
        return isBom() || processes.stream().anyMatch(process -> Boolean.TRUE.equals(process.required()));
    }
}
