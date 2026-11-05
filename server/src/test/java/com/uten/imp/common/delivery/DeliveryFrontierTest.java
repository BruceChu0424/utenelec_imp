package com.uten.imp.common.delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.common.delivery.DeliveryBom.*;
import static com.uten.imp.common.delivery.DeliveryPlan.*;
import static org.assertj.core.api.Assertions.*;

class DeliveryFrontierTest {
    private static UUID id(String value) { return UUID.nameUUIDFromBytes(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
    private Node node(String name, String qty, List<UUID> parent, ChildrenState state, boolean mandatory,
            MaterialRole role, List<Operation> operations, java.util.function.Function<List<UUID>,List<Node>> children) {
        List<UUID> path = new ArrayList<>(parent); path.add(id(name));
        return new Node(path, id(name), id("goods-"+name), name, name, id("unit"), "个", null, null, "spec",
                "自制", qty, "PER_UNIT", "1", true, state, mandatory, role, operations, children.apply(path));
    }
    private Node leaf(String name, String qty, List<UUID> parent) {
        return node(name, qty, parent, ChildrenState.NONE, false, MaterialRole.PART, List.of(), p -> List.of());
    }
    private Snapshot example() {
        List<Node> groups = new ArrayList<>();
        for (String group : List.of("left", "middle", "right")) groups.add(node(group, "1", List.of(), ChildrenState.LOADED,
                false, MaterialRole.PART, List.of(), p -> List.of(leaf("shared", "0.0002", p),
                    node("locked", "2", p, ChildrenState.LOADED, true, MaterialRole.PART, List.of(Operation.LASER),
                            pp -> List.of(leaf("inside", "3", pp))),
                    node("unknown", "1", p, ChildrenState.MISSING, false, MaterialRole.PART, List.of(), pp -> List.of()))));
        groups.add(node("socket", "2", List.of(), ChildrenState.MISSING, false, MaterialRole.PART, List.of(), p -> List.of()));
        groups.add(node("pack", "0.2", List.of(), ChildrenState.NONE, false, MaterialRole.PRODUCT_PACKAGING, List.of(), p -> List.of()));
        groups.add(node("manual", "1", List.of(), ChildrenState.NONE, false, MaterialRole.ACCESSORY, List.of(), p -> List.of()));
        Node root = new Node(List.of(), null, id("product"), "product", "product", id("unit"), "个", null, null, "spec", "自制",
                "1", "PER_UNIT", "1", true, ChildrenState.LOADED, false, MaterialRole.PART, List.of(), groups);
        return new Snapshot(1, id("product"), "fingerprint", root);
    }
    private DeliveryPlan plan(Mode mode, Packaging packaging, List<NodeMode> choices, List<DeliveryPlan.Process> operations) {
        return new DeliveryPlan(1, mode, packaging, choices, operations, "fingerprint");
    }
    @Test void everyKnownSelectionPreservesMutuallyExclusiveFrontierAndExactQuantities() {
        Snapshot snapshot = example();
        for (int bits=0; bits<8; bits++) for (String quantity : List.of("1", "100", "1000000")) {
            List<NodeMode> choices = new ArrayList<>();
            for (int group=0; group<3; group++) choices.add(new NodeMode(List.of(id(List.of("left","middle","right").get(group))),
                    (bits & (1<<group)) == 0 ? NodeDelivery.WHOLE : NodeDelivery.CHILDREN));
            Preview preview = DeliveryFrontier.resolve(snapshot, new BigDecimal(quantity), plan(Mode.BOM, Packaging.BULK, choices, List.of()));
            assertThat(preview.issues()).isEmpty();
            assertThat(preview.items()).noneMatch(item -> "pack".equals(item.code()));
            assertThat(preview.items()).filteredOn(item -> item.code().equals("socket")).singleElement()
                    .satisfies(item -> assertThat(item.quantity()).isEqualByComparingTo(new BigDecimal(quantity).multiply(new BigDecimal("2"))));
            for (Item a : preview.items()) for (Item b : preview.items()) if (a != b)
                assertThat(b.path().size()>a.path().size() && b.path().subList(0,a.path().size()).equals(a.path())).isFalse();
            for (Item item : preview.items()) if ("shared".equals(item.code()))
                assertThat(item.quantity()).isEqualByComparingTo(new BigDecimal(quantity).multiply(new BigDecimal("0.0002")));
        }
    }
    @Test void wholeAncestorCoversInvalidDescendantSplitsWithoutDroppingNecessaryOperations() {
        var unknownPath = List.of(id("left"),id("unknown"));
        var lockedPath = List.of(id("left"),id("locked"));
        var hidden = List.of(new NodeMode(unknownPath,NodeDelivery.CHILDREN),new NodeMode(lockedPath,NodeDelivery.CHILDREN));
        Preview assembled = DeliveryFrontier.resolve(example(), new BigDecimal("100"), plan(Mode.ASSEMBLED,Packaging.ORIGINAL,hidden,List.of()));
        assertThat(assembled.issues()).isEmpty(); assertThat(assembled.items()).hasSize(1);
        assertThat(assembled.items().getFirst().operations()).contains(Operation.LASER);
        assertThat(assembled.deliveryPlan().requiresPhysicalFulfillment()).isTrue();
        assertThat(assembled.deliveryPlan().processes()).extracting(DeliveryPlan.Process::path).contains(lockedPath);
        assertThat(assembled.deliveryPlan().processes()).noneMatch(operation -> operation.path().isEmpty());
        Preview keptGroup = DeliveryFrontier.resolve(example(), new BigDecimal("100"), plan(Mode.BOM,Packaging.ORIGINAL,hidden,List.of()));
        assertThat(keptGroup.issues()).isEmpty();
        List<NodeMode> active = new ArrayList<>(hidden); active.add(new NodeMode(List.of(id("left")),NodeDelivery.CHILDREN));
        Preview blocked = DeliveryFrontier.resolve(example(),new BigDecimal("100"),plan(Mode.BOM,Packaging.ORIGINAL,active,List.of()));
        assertThat(blocked.issues()).extracting(Issue::path).contains(unknownPath,lockedPath);
        assertThat(blocked.items()).noneMatch(item -> item.path().equals(unknownPath)||item.path().equals(lockedPath));
    }
    @Test void originalAndBulkPackagingNeverRemoveAccessoriesAndPendingRemainsExplicit() {
        Preview original = DeliveryFrontier.resolve(example(),new BigDecimal("0.1"),plan(Mode.BOM,Packaging.ORIGINAL,List.of(),List.of()));
        assertThat(original.items()).filteredOn(item -> item.code().equals("pack")).singleElement()
                .satisfies(item -> assertThat(item.quantityExact()).isEqualTo("0.02"));
        for (Packaging packaging : List.of(Packaging.BULK,Packaging.PENDING)) {
            Preview preview=DeliveryFrontier.resolve(example(),new BigDecimal("100"),plan(Mode.BOM,packaging,List.of(),List.of()));
            assertThat(preview.deliveryPlan().packaging()).isEqualTo(packaging);
            assertThat(preview.items()).extracting(Item::code).contains("manual").doesNotContain("pack");
            assertThat(preview.root().children()).extracting(Node::code).contains("pack");
        }
    }
    @Test void forgedPathsDuplicateRulesAndRemovingOperationsAreRejected() {
        var wrong = new NodeMode(List.of(id("foreign-edge")),NodeDelivery.CHILDREN);
        var same = new NodeMode(List.of(id("left")),NodeDelivery.WHOLE);
        Preview result = DeliveryFrontier.resolve(example(),BigDecimal.ONE,plan(Mode.BOM,Packaging.ORIGINAL,List.of(wrong,same,same),
                List.of(new DeliveryPlan.Process(List.of(id("left")),Operation.LASER,false))));
        assertThat(result.issues()).hasSize(3);
    }
    @Test void effectiveParentLaserCannotSilentlyDisappearWhenItsAssemblyIsRemoved() {
        var path=List.of(id("left"));
        Preview result=DeliveryFrontier.resolve(example(),BigDecimal.ONE,plan(Mode.BOM,Packaging.ORIGINAL,
                List.of(new NodeMode(path,NodeDelivery.CHILDREN)),List.of(new DeliveryPlan.Process(path,Operation.LASER,true))));
        assertThat(result.issues()).anyMatch(issue -> issue.path().equals(path) && issue.message().contains("必要加工"));
    }
    @Test void jsonContainsOnlyTheVersionedIntentAndNoComputedBeanProperties() throws Exception {
        ObjectMapper mapper=new ObjectMapper(); DeliveryPlan source=plan(Mode.BOM,Packaging.BULK,List.of(),List.of());
        String json=mapper.writeValueAsString(source);
        assertThat(json).doesNotContain("\"bom\":");
        assertThat(json).doesNotContain("requiresPhysicalFulfillment");
        assertThat(mapper.readValue(json,DeliveryPlan.class)).isEqualTo(source);
        assertThat(mapper.writeValueAsString(example())).doesNotContain("price","stock","amount");
    }
    @Test void invalidVersionAndNonPositiveQuantityAreExplicitIssues() {
        var result=DeliveryFrontier.resolve(example(),BigDecimal.ZERO,new DeliveryPlan(2,Mode.BOM,Packaging.ORIGINAL,List.of(),List.of(),null));
        assertThat(result.issues()).hasSize(2); assertThat(result.items()).isEmpty();
    }
    @Test void verySmallTerminatingDesignUseIsNeverSilentlyRoundedUpToTwelvePlaces() {
        Node source=example().root();
        Node root=new Node(source.path(),source.edgeId(),source.goodsId(),source.code(),source.name(),source.unitId(),
                source.unitName(),source.colorId(),source.colorName(),source.spec(),source.sourceType(),source.qtyExact(),
                source.consumptionBasis(),source.basisOutputQtyExact(),source.allowPartialPackage(),source.childrenState(),
                source.mandatoryAssembly(),source.materialRole(),source.requiredOperations(),List.of(leaf("tiny","0.0000000000000002",List.of())));
        Preview result=DeliveryFrontier.resolve(new Snapshot(1,source.goodsId(),"tiny",root),BigDecimal.ONE,
                plan(Mode.BOM,Packaging.ORIGINAL,List.of(),List.of()));
        assertThat(result.items().getFirst().quantityExact()).isEqualTo("0.0000000000000002");
    }
    @Test void bulkPackagingCannotSilentlyRemoveNecessaryWork() {
        var base=example();var packaging=node("work-package","1",List.of(),ChildrenState.NONE,false,
                MaterialRole.PRODUCT_PACKAGING,List.of(Operation.LASER),p->List.of());
        var result=DeliveryFrontier.resolve(withChildren(base,List.of(packaging)),BigDecimal.TEN,plan(Mode.BOM,Packaging.BULK,List.of(),List.of()));
        assertThat(result.issues()).anyMatch(issue->issue.message().contains("必要加工"));
        assertThat(result.deliveryPlan().processes()).anyMatch(process->process.path().equals(packaging.path())&&process.operation()==Operation.LASER);
    }
    @Test void bulkPackagingCannotSwallowAnAccessoryBelowThePackagingParent() {
        var base=example();var packaging=node("kit-box","1",List.of(),ChildrenState.LOADED,false,MaterialRole.PRODUCT_PACKAGING,List.of(),
                p->List.of(node("instructions","1",p,ChildrenState.NONE,false,MaterialRole.ACCESSORY,List.of(),unused->List.of())));
        var result=DeliveryFrontier.resolve(withChildren(base,List.of(packaging)),BigDecimal.TEN,plan(Mode.BOM,Packaging.BULK,List.of(),List.of()));
        assertThat(result.issues()).anyMatch(issue->issue.message().contains("附件"));
    }
    private static Snapshot withChildren(Snapshot snapshot,List<Node> children){
        var root=snapshot.root();return new Snapshot(1,snapshot.goodsId(),snapshot.bomFingerprint(),new Node(root.path(),root.edgeId(),root.goodsId(),root.code(),root.name(),
                root.unitId(),root.unitName(),root.colorId(),root.colorName(),root.spec(),root.sourceType(),root.qtyExact(),root.consumptionBasis(),root.basisOutputQtyExact(),
                root.allowPartialPackage(),root.childrenState(),root.mandatoryAssembly(),root.materialRole(),root.requiredOperations(),children));
    }
    @Test void unresolvedLegacyColourOnAnActualDeliveryBoundaryNeverBecomesTheMasterDefaultColour() {
        var bad=withIdentity(leaf("legacy-colour","1",List.of()),List.of("ROW_COLOR_LEGACY"));
        var result=DeliveryFrontier.resolve(withChildren(example(),List.of(bad)),BigDecimal.TEN,
                plan(Mode.BOM,Packaging.ORIGINAL,List.of(),List.of()));
        assertThat(result.issues()).anyMatch(issue->issue.path().equals(bad.path())&&issue.message().contains("老系统引用"));
        assertThat(result.items()).isEmpty();assertThat(result.root().children().getFirst().colorId()).isNull();
    }
    @Test void aWholeBoundaryCoversBadDescendantIdentityButActivatingThatDescendantBlocksIt() {
        var parent=node("valid-whole","1",List.of(),ChildrenState.LOADED,false,MaterialRole.PART,List.of(),
                path->List.of(withIdentity(leaf("missing-unit","2",path),List.of("UNIT_MISSING"))));
        var snapshot=withChildren(example(),List.of(parent));
        var kept=DeliveryFrontier.resolve(snapshot,BigDecimal.TEN,plan(Mode.BOM,Packaging.ORIGINAL,List.of(),List.of()));
        assertThat(kept.issues()).isEmpty();assertThat(kept.items()).extracting(Item::code).containsExactly("valid-whole");
        var split=DeliveryFrontier.resolve(snapshot,BigDecimal.TEN,plan(Mode.BOM,Packaging.ORIGINAL,
                List.of(new NodeMode(parent.path(),NodeDelivery.CHILDREN)),List.of()));
        assertThat(split.issues()).anyMatch(issue->issue.message().contains("基本单位"));assertThat(split.items()).isEmpty();
    }
    private static Node withIdentity(Node node,List<String> problems){
        return new Node(node.path(),node.edgeId(),node.goodsId(),node.code(),node.name(),problems.contains("UNIT_MISSING")?null:node.unitId(),
                node.unitName(),node.colorId(),node.colorName(),node.spec(),node.sourceType(),node.qtyExact(),node.consumptionBasis(),node.basisOutputQtyExact(),
                node.allowPartialPackage(),node.childrenState(),node.mandatoryAssembly(),node.materialRole(),node.requiredOperations(),node.children(),problems);
    }
}
