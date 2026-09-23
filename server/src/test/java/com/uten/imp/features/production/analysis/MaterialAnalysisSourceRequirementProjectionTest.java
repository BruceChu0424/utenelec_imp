package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisSourceRequirementProjection.Node;
import static com.uten.imp.features.production.analysis.MaterialAnalysisSourceRequirementProjection.Source;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MaterialAnalysisSourceRequirementProjectionTest {
    @Test void keepsTheSourceTreeIndependentOfAnUnrelatedLargerAnchorAndInputOrdering() {
        UUID source = UUID.randomUUID();
        UUID anchor = UUID.randomUUID();
        Node root = root(source);
        Node component = node(source, "component", null, 1, "2", "PER_UNIT", "1", true);
        Node child = node(source, "component/child", "component", 2, "3", "PER_UNIT", "1", true);

        Map<UUID, BigDecimal> result = project(List.of(source(source, "1000", "1"), source(anchor, "9000", "1")),
                List.of(child, component, root));

        qty(result, root, "1000");
        qty(result, component, "2000");
        qty(result, child, "6000");
        assertThrows(UnsupportedOperationException.class, () -> result.put(UUID.randomUUID(), BigDecimal.TEN));
    }

    @Test void identicalBomPathsBelongToTheirOwnSourceLines() {
        UUID firstSource = UUID.randomUUID();
        UUID secondSource = UUID.randomUUID();
        Node first = node(firstSource, "same-component", null, 1, "3", "PER_UNIT", "1", true);
        Node second = node(secondSource, "same-component", null, 1, "3", "PER_UNIT", "1", true);

        Map<UUID, BigDecimal> result = project(List.of(source(firstSource, "2", "1"), source(secondSource, "5", "1")),
                List.of(second, first));

        qty(result, first, "6");
        qty(result, second, "15");
    }

    @Test void fixedBatchAndWholePackageRoundingHappenOnEveryParentEdge() {
        UUID source = UUID.randomUUID();
        Node batch = node(source, "batch", null, 1, "10", "FIXED_BATCH", "100", true);
        Node child = node(source, "batch/child", "batch", 2, "1", "FIXED_BATCH", "6", false);
        Node whole = node(source, "whole", null, 1, "2", "PER_PACKAGE", "100", false);
        Node partial = node(source, "partial", null, 1, "2", "PER_PACKAGE", "100", true);

        Map<UUID, BigDecimal> result = project(List.of(source(source, "101", "1")),
                List.of(child, whole, partial, batch));

        qty(result, batch, "20");
        qty(result, child, "4");
        qty(result, whole, "4");
        qty(result, partial, "2.02");
    }

    @Test void preservesExactUnitConversionUntilTheFirstBomEdgeThenRoundsEachMaterialUp() {
        UUID source = UUID.randomUUID();
        Node root = root(source);
        Node implicit = node(source, "implicit", null, 1, "100", "PER_UNIT", "1", true);
        Node explicit = node(source, "explicit", "ROOT_SUPPLY", 1, "100", "PER_UNIT", "1", true);
        Node child = node(source, "implicit/child", "implicit", 2, "100", "PER_UNIT", "1", true);

        Map<UUID, BigDecimal> result = project(List.of(source(source, "0.0001", "0.333333333333")),
                List.of(child, explicit, root, implicit));

        qty(result, root, "0.0001");
        qty(result, implicit, "0.0034");
        qty(result, explicit, "0.0034");
        qty(result, child, "0.3400");
    }

    @Test void aStandaloneSourceDoesNotNeedASyntheticRootRowAndZeroIsAnActualSourceQuantity() {
        UUID source = UUID.randomUUID();
        Node component = node(source, "component", null, 1, "3", "FIXED_BATCH", "10", false);
        Map<UUID, BigDecimal> result = project(List.of(source(source, "0", "2.5")), List.of(component));
        qty(result, component, "0");
    }

    @Test void missingSourceOrParentCannotFallBackToZeroOrAnotherSourcesIdenticalPath() {
        UUID source = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        Node child = node(source, "parent/child", "parent", 2, "1", "PER_UNIT", "1", true);
        Node foreignParent = node(other, "parent", null, 1, "1", "PER_UNIT", "1", true);
        assertThrows(IllegalArgumentException.class, () -> project(List.of(), List.of(child)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(source(source, "5", "1")), List.of(child)));
        assertThrows(IllegalArgumentException.class, () -> project(
                List.of(source(source, "5", "1"), source(other, "10", "1")), List.of(child, foreignParent)));
    }

    @Test void duplicateSourcesMaterialIdsAndPathsAreRejectedInsteadOfCountedTwice() {
        UUID source = UUID.randomUUID();
        Source input = source(source, "5", "1");
        Node first = node(source, "component", null, 1, "1", "PER_UNIT", "1", true);
        Node duplicatePath = node(source, "component", null, 1, "2", "PER_UNIT", "1", true);
        Node duplicateId = new Node(first.id(), source, "other-path", null, 1,
                BigDecimal.ONE, "PER_UNIT", BigDecimal.ONE, true);
        assertThrows(IllegalArgumentException.class, () -> project(List.of(input, input), List.of(first)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(input), List.of(first, duplicatePath)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(input), List.of(first, duplicateId)));
    }

    @Test void invalidLevelsAndCyclesAreRejectedWithoutRecursiveTraversal() {
        UUID source = UUID.randomUUID();
        Source input = source(source, "5", "1");
        Node skippedLevel = node(source, "child", "ROOT_SUPPLY", 2, "1", "PER_UNIT", "1", true);
        Node cycleA = node(source, "a", "b", 1, "1", "PER_UNIT", "1", true);
        Node cycleB = node(source, "b", "a", 2, "1", "PER_UNIT", "1", true);
        assertThrows(IllegalArgumentException.class, () -> project(List.of(input), List.of(root(source), skippedLevel)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(input), List.of(cycleA, cycleB)));
    }

    @Test void invalidQuantitiesRatesAndConsumptionRulesAreNotSilentlyAcceptedEvenForZeroOutput() {
        UUID source = UUID.randomUUID();
        Node valid = node(source, "component", null, 1, "1", "PER_UNIT", "1", true);
        assertThrows(IllegalArgumentException.class, () -> project(List.of(source(source, "-1", "1")), List.of(valid)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(source(source, "1", "0")), List.of(valid)));
        Node invalidRule = node(source, "invalid", null, 1, "1", "UNKNOWN", "1", true);
        Node zeroBasis = node(source, "invalid", null, 1, "1", "FIXED_BATCH", "0", true);
        assertThrows(IllegalArgumentException.class, () -> project(List.of(source(source, "0", "1")), List.of(invalidRule)));
        assertThrows(IllegalArgumentException.class, () -> project(List.of(source(source, "0", "1")), List.of(zeroBasis)));
    }

    private static Map<UUID, BigDecimal> project(List<Source> sources, List<Node> nodes) {
        return MaterialAnalysisSourceRequirementProjection.project(sources, nodes);
    }

    private static Source source(UUID id, String qty, String rate) {
        return new Source(id, new BigDecimal(qty), new BigDecimal(rate));
    }

    private static Node root(UUID source) {
        return new Node(UUID.randomUUID(), source, "ROOT_SUPPLY", null, 0,
                null, null, null, false);
    }

    private static Node node(UUID source, String key, String parent, int level,
                             String bom, String basis, String outputBasis, boolean partial) {
        return new Node(UUID.randomUUID(), source, key, parent, level,
                new BigDecimal(bom), basis, new BigDecimal(outputBasis), partial);
    }

    private static void qty(Map<UUID, BigDecimal> result, Node node, String expected) {
        assertThat(result.get(node.id())).isEqualByComparingTo(expected);
        assertThat(result.get(node.id()).scale()).isEqualTo(4);
    }
}
