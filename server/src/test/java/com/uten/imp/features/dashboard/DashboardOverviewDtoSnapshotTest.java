package com.uten.imp.features.dashboard;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DashboardOverviewDtoSnapshotTest {
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
