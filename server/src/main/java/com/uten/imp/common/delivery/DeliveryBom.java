package com.uten.imp.common.delivery;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Price-free, stock-free authoritative recipe snapshot and its resolved delivery frontier. */
public final class DeliveryBom {
    private DeliveryBom() {}
    public enum ChildrenState { LOADED, MISSING, NONE }
    public enum MaterialRole { PART, ACCESSORY, PRODUCT_PACKAGING, UNCLASSIFIED }
    public record Node(List<UUID> path, UUID edgeId, UUID goodsId, String code, String name,
            UUID unitId, String unitName, UUID colorId, String colorName, String spec,
            String sourceType, String qtyExact, String consumptionBasis, String basisOutputQtyExact,
            boolean allowPartialPackage, ChildrenState childrenState, boolean mandatoryAssembly,
            MaterialRole materialRole, List<DeliveryPlan.Operation> requiredOperations, List<Node> children,
            List<String> identityIssues) {
        public Node {
            path = List.copyOf(path); children = List.copyOf(children);
            requiredOperations = List.copyOf(requiredOperations);
            identityIssues=identityIssues==null?List.of():List.copyOf(identityIssues);
        }
        public Node(List<UUID> path,UUID edgeId,UUID goodsId,String code,String name,UUID unitId,String unitName,
                UUID colorId,String colorName,String spec,String sourceType,String qtyExact,String consumptionBasis,
                String basisOutputQtyExact,boolean allowPartialPackage,ChildrenState childrenState,boolean mandatoryAssembly,
                MaterialRole materialRole,List<DeliveryPlan.Operation> requiredOperations,List<Node> children) {
            this(path,edgeId,goodsId,code,name,unitId,unitName,colorId,colorName,spec,sourceType,qtyExact,consumptionBasis,
                    basisOutputQtyExact,allowPartialPackage,childrenState,mandatoryAssembly,materialRole,requiredOperations,children,List.of());
        }
    }
    public record Snapshot(int version, UUID goodsId, String bomFingerprint, Node root) {}
    /** Constructed only from an admitted persisted document row; never an HTTP request DTO. */
    public record AdmittedSource(UUID goodsId,UUID unitId,BigDecimal unitRate,BigDecimal qty,
            DeliveryPlan deliveryPlan,Snapshot frozenSnapshot) {}
    public record Issue(List<UUID> path, String message) { public Issue { path = List.copyOf(path); } }
    public record Item(List<UUID> path, UUID goodsId, UUID colorId, UUID unitId, String unitName,
            String code, String name, String spec, String sourceType,
            BigDecimal quantity, String quantityExact, String perRootExact,
            String quantityNumerator, String quantityDenominator,
            List<DeliveryPlan.Operation> operations) {
        public Item { path = List.copyOf(path); operations = List.copyOf(operations); }
    }
    public record Preview(DeliveryPlan deliveryPlan, String bomFingerprint, Node root,
            List<Item> items, List<Issue> issues) {
        public Preview { items = List.copyOf(items); issues = List.copyOf(issues); }
    }
}
