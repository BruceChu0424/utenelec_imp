package com.uten.imp.common.delivery;

import com.uten.imp.common.finance.BomConsumptionCurve;
import com.uten.imp.common.finance.CostFraction;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.common.delivery.DeliveryPlan.*;
import static com.uten.imp.common.delivery.DeliveryBom.*;

/** One Java delivery calculation for sales, planning and downstream consumers. */
public final class DeliveryFrontier {
    private DeliveryFrontier() {}
    public static Preview resolve(Snapshot snapshot, BigDecimal baseQuantity, DeliveryPlan request) {
        DeliveryPlan input = request == null ? DeliveryPlan.assembled() : request;
        List<Issue> issues = new ArrayList<>();
        if (!Objects.equals(input.version(), 1) || input.mode() == null || input.packaging() == null)
            issues.add(new Issue(List.of(), "不支持的交付方案版本、模式或包装安排"));
        if (baseQuantity == null || baseQuantity.signum() <= 0)
            issues.add(new Issue(List.of(), "交付数量必须大于零"));
        if (input.nodeModes().size() > 10000 || input.processes().size() > 10000)
            issues.add(new Issue(List.of(), "交付配置超过单次允许的节点数"));
        Map<List<UUID>, Node> nodes = new LinkedHashMap<>(); index(snapshot.root(), nodes);
        Map<List<UUID>, NodeDelivery> modes = new HashMap<>();
        for (NodeMode choice : input.nodeModes()) {
            if (choice == null || choice.mode() == null || choice.path().isEmpty() || !nodes.containsKey(choice.path())) {
                issues.add(new Issue(choice == null ? List.of() : choice.path(), "交付路径不存在或不是本产品的BOM边")); continue;
            }
            if (modes.putIfAbsent(choice.path(), choice.mode()) != null)
                issues.add(new Issue(choice.path(), "同一BOM路径不能重复配置"));
        }
        Map<List<UUID>, EnumSet<Operation>> operations = new HashMap<>();
        for (DeliveryPlan.Process process : input.processes()) {
            if (process == null || process.operation() == null || !Boolean.TRUE.equals(process.required())
                    || !nodes.containsKey(process.path())) {
                issues.add(new Issue(process == null ? List.of() : process.path(), "必要工序路径或要求无效，不能取消必要工序")); continue;
            }
            if (!operations.computeIfAbsent(process.path(), p -> EnumSet.noneOf(Operation.class)).add(process.operation()))
                issues.add(new Issue(process.path(), "同一路径不能重复添加相同工序"));
        }
        List<Item> result = new ArrayList<>();
        if (baseQuantity != null && baseQuantity.signum() > 0 && input.mode() != null && input.packaging() != null)
            walk(snapshot.root(), CostFraction.of(baseQuantity), CostFraction.of(BigDecimal.ONE),
                    input.mode() == Mode.BOM, true, input, modes, operations, result, issues);
        List<NodeMode> normalizedModes = input.nodeModes().stream().filter(Objects::nonNull)
                .sorted(Comparator.comparing(n -> n.path().toString())).toList();
        Map<String,DeliveryPlan.Process> canonicalOperations=new LinkedHashMap<>();
        for (DeliveryPlan.Process process : input.processes()) if(process!=null)
            canonicalOperations.put(process.path()+":"+process.operation(),process);
        // Master-required work is part of the frozen order contract at its real edge occurrence,
        // even when a whole ancestor covers the component for physical delivery.
        for (Node node : nodes.values()) for(Operation operation:node.requiredOperations())
            canonicalOperations.put(node.path()+":"+operation,new DeliveryPlan.Process(node.path(),operation,true));
        List<DeliveryPlan.Process> normalizedProcesses = canonicalOperations.values().stream()
                .sorted(Comparator.comparing((DeliveryPlan.Process n) -> n.path().toString()).thenComparing(n -> String.valueOf(n.operation()))).toList();
        DeliveryPlan normalized = new DeliveryPlan(1, input.mode(), input.packaging(), normalizedModes,
                normalizedProcesses, snapshot.bomFingerprint());
        return new Preview(normalized, snapshot.bomFingerprint(), snapshot.root(), result, issues);
    }
    private static void index(Node node, Map<List<UUID>, Node> target) {
        target.put(node.path(), node); node.children().forEach(child -> index(child, target));
    }
    private static void walk(Node node, CostFraction qty, CostFraction perRoot, boolean split, boolean linear,
            DeliveryPlan plan, Map<List<UUID>, NodeDelivery> modes, Map<List<UUID>, EnumSet<Operation>> requested,
            List<Item> result, List<Issue> issues) {
        if (excludePackaging(node,plan,requested,issues)) return;
        List<String> invalidIdentity=node.identityIssues().stream()
                .filter(problem->!split || !problem.contains("COLOR")).toList();
        if(!invalidIdentity.isEmpty()){
            issues.add(new Issue(node.path(),identityMessage(invalidIdentity)));return;
        }
        if (split) {
            if (node.mandatoryAssembly() || node.childrenState() != ChildrenState.LOADED || node.children().isEmpty()) {
                issues.add(new Issue(node.path(), node.mandatoryAssembly() ? "本组件必须组装后交付"
                        : node.childrenState() == ChildrenState.MISSING ? "原始下级BOM缺失或存在循环，不能按下级交付" : "本节点没有下级BOM")); return;
            }
            // An operation on a transparent assembly cannot vanish with its assembly step.
            if (!node.requiredOperations().isEmpty() || requested.containsKey(node.path())) {
                issues.add(new Issue(node.path(), "该节点有必要加工工序，请保留整件或将工序明确配置到实际交付件")); return;
            }
            for (Node child : node.children()) {
                if (excludePackaging(child,plan,requested,issues)) continue;
                try {
                    if(child.qtyExact()==null || child.basisOutputQtyExact()==null) throw new IllegalArgumentException();
                    BigDecimal use = new BigDecimal(child.qtyExact()), base = new BigDecimal(child.basisOutputQtyExact());
                    if (use.signum() <= 0 || base.signum() <= 0) throw new IllegalArgumentException();
                    CostFraction childQty = BomConsumptionCurve.exact(qty, use, child.consumptionBasis(), base, child.allowPartialPackage());
                    CostFraction childPer = BomConsumptionCurve.exact(perRoot, use, child.consumptionBasis(), base, child.allowPartialPackage());
                    boolean childLinear=linear && ("PER_UNIT".equals(child.consumptionBasis())
                            || "PER_PACKAGE".equals(child.consumptionBasis()) && child.allowPartialPackage());
                    walk(child, childQty, childPer, modes.getOrDefault(child.path(), NodeDelivery.WHOLE) == NodeDelivery.CHILDREN, childLinear,
                            plan, modes, requested, result, issues);
                } catch (IllegalArgumentException | ArithmeticException ex) {
                    issues.add(new Issue(child.path(), "直属父件的设计单耗或计量基准无效，请先核对原始BOM"));
                }
            }
        } else {
            EnumSet<Operation> active = EnumSet.noneOf(Operation.class); active.addAll(node.requiredOperations());
            active.addAll(requested.getOrDefault(node.path(), EnumSet.noneOf(Operation.class)));
            // A stored operation below a whole delivered ancestor must still remain visible/required.
            collectCoveredOperations(node, requested, active);
            // Keep exact terminating decimals, including deep products. A recurring fraction or >30 places
            // uses the existing per-purpose precision choice, never an invented 12-place round-up.
            BigDecimal projection = qty.project("delivery.quantity:" + node.path(), "本次交付数量", 30).stripTrailingZeros();
            result.add(new Item(node.path(), node.goodsId(), node.colorId(), node.unitId(), node.unitName(),
                    node.code(), node.name(), node.spec(), node.sourceType(), projection, text(projection),
                    linear ? exactOrNull(perRoot) : null, qty.numerator().toString(), qty.denominator().toString(), List.copyOf(active)));
        }
    }
    private static void collectCoveredOperations(Node parent, Map<List<UUID>, EnumSet<Operation>> requested, Set<Operation> result) {
        for (Node child : parent.children()) {
            result.addAll(child.requiredOperations()); result.addAll(requested.getOrDefault(child.path(), EnumSet.noneOf(Operation.class)));
            collectCoveredOperations(child, requested, result);
        }
    }
    private static boolean excludePackaging(Node node,DeliveryPlan plan,Map<List<UUID>,EnumSet<Operation>> requested,List<Issue> issues) {
        if(node.path().isEmpty()||node.materialRole()!=MaterialRole.PRODUCT_PACKAGING||plan.mode()!=Mode.BOM||plan.packaging()==Packaging.ORIGINAL)return false;
        if(plan.packaging()==Packaging.BULK){
            if(hasRequiredWork(node,requested))issues.add(new Issue(node.path(),"该包装或其下级有必要加工，不能随整批包装设置删除，请工程明确替代规则"));
            if(hasAccessory(node))issues.add(new Issue(node.path(),"该包装下还有随货附件，不能整层移除，请工程明确替代包装和附件去向"));
        }
        return true;
    }
    private static boolean hasRequiredWork(Node node,Map<List<UUID>,EnumSet<Operation>> requested){
        return !node.requiredOperations().isEmpty()||requested.containsKey(node.path())||node.children().stream().anyMatch(child->hasRequiredWork(child,requested));
    }
    private static boolean hasAccessory(Node node){
        return node.materialRole()==MaterialRole.ACCESSORY||node.children().stream().anyMatch(DeliveryFrontier::hasAccessory);
    }
    private static String identityMessage(List<String> problems){
        if(problems.stream().anyMatch(problem->problem.startsWith("UNIT")))return "该交付路径缺少有效的新系统基本单位，请先核对原货品资料";
        if(problems.stream().anyMatch(problem->problem.contains("COLOR")))return "该交付路径的颜色已删除或仍是未对应的老系统引用，不能猜成主颜色或无色";
        return "该交付路径的货品已删除、停用或为迁移占位，请先核对原资料";
    }
    private static String text(BigDecimal value) { return value.stripTrailingZeros().toPlainString(); }
    private static String exactOrNull(CostFraction value) {
        try { return text(new BigDecimal(value.numerator()).divide(new BigDecimal(value.denominator()))); }
        catch (ArithmeticException recurring) { return null; }
    }
}
