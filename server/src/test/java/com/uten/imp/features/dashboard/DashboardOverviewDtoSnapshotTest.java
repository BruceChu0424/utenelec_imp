package com.uten.imp.features.dashboard;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DashboardOverviewDtoSnapshotTest {
    @Test
    void wireRoundTripPreservesTheFiveFieldsAndSnapshotValue() throws Exception {
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules();
        var metric = new DashboardOverviewDto.MetricCard("m", "title", "1", "", "", "", false);
        var todo = new DashboardOverviewDto.TodoCard("t", "title", "", 1, 0, "", "", "TASK", null, null, false);
        var snapshot = new DashboardOverviewDto("D", "department", Instant.EPOCH, List.of(metric), List.of(todo));
        byte[] wire = mapper.writeValueAsBytes(snapshot);
        var fields = new ArrayList<String>();
        mapper.readTree(wire).fieldNames().forEachRemaining(fields::add);
        assertThat(fields).containsExactly("departmentCode", "departmentName", "generatedAt", "metrics", "todos");
        var restored = mapper.readValue(wire, DashboardOverviewDto.class);
        assertThat(restored).isEqualTo(snapshot);
        assertThat(restored.hashCode()).isEqualTo(snapshot.hashCode());
        assertThat(restored.toString()).isEqualTo(snapshot.toString());
        assertThatThrownBy(() -> restored.metrics().clear()).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> restored.todos().clear()).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void snapshotsOwnTheirCollectionsAndExposeOnlyReadOnlyViews() {
        var metric = new DashboardOverviewDto.MetricCard("m", "title", "1", "", "", "", false);
        var todo = new DashboardOverviewDto.TodoCard("t", "title", "", 1, 0, "", "", "TASK", null, null, false);
        var metrics = new ArrayList<>(List.of(metric));
        var todos = new ArrayList<>(List.of(todo));
        var snapshot = new DashboardOverviewDto("D", "department", Instant.EPOCH, metrics, todos);
        metrics.clear();
        todos.clear();
        assertThat(snapshot.metrics()).containsExactly(metric);
        assertThat(snapshot.todos()).containsExactly(todo);
        assertThatThrownBy(() -> snapshot.metrics().clear()).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> snapshot.todos().clear()).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void nullableReadModelFieldsRetainTheirExistingShape() {
        var snapshot = new DashboardOverviewDto(null, null, null, null, null);
        assertThat(snapshot.departmentCode()).isNull();
        assertThat(snapshot.departmentName()).isNull();
        assertThat(snapshot.generatedAt()).isNull();
        assertThat(snapshot.metrics()).isNull();
        assertThat(snapshot.todos()).isNull();
    }
}
