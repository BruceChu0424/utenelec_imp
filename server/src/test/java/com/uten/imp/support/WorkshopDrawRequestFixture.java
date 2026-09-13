package com.uten.imp.support;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * V559/V564 起：实物领料数量不得超过车间申请量，事件约束与守卫共同要求
 * {@code created_by IS NOT NULL}、{@code resulting_version = expected_version + 1}
 * 且 {@code segment.lock_version = resulting_version}。直插 SQL 的夹具借这里
 * 为整个备料包补一组全量 DRAW_REQUEST 事件（每段版本号同步 +1）。
 */
public final class WorkshopDrawRequestFixture {
    private WorkshopDrawRequestFixture() {}

    private record RequestRow(UUID segmentId, long version, UUID documentId, UUID actorId) {}

    public static void openFullRequest(Connection connection, UUID packageId) throws SQLException {
        String mapping = "select mapping.execution_segment_id, segment.lock_version, mapping.document_id, segment.created_by from production_execution_segments segment join production_planning_package_documents mapping on mapping.execution_segment_id = segment.id where mapping.package_id = ? and mapping.document_type = 'DRAW'";
        String bump = "update production_execution_segments set lock_version = ? where id = ?";
        String insert = "insert into production_execution_segment_events(execution_segment_id, action, idempotency_key, request_hash, expected_version, resulting_version, draw_document_ids, created_by) values (?, 'DRAW_REQUEST', ?, ?, ?, ?, array[?], ?)";
        List<RequestRow> rows = new ArrayList<>();
        try (PreparedStatement query = connection.prepareStatement(mapping)) {
            query.setObject(1, packageId);
            try (ResultSet result = query.executeQuery()) {
                while (result.next()) {
                    UUID actor = result.getObject(4, UUID.class);
                    if (actor == null) {
                        actor = firstUserId(connection);
                    }
                    rows.add(new RequestRow(result.getObject(1, UUID.class), result.getLong(2),
                            result.getObject(3, UUID.class), actor));
                }
            }
        }
        try (PreparedStatement bumpRow = connection.prepareStatement(bump);
             PreparedStatement insertRow = connection.prepareStatement(insert)) {
            for (RequestRow row : rows) {
                bumpRow.setLong(1, row.version() + 1);
                bumpRow.setObject(2, row.segmentId());
                bumpRow.executeUpdate();
                insertRow.setObject(1, row.segmentId());
                insertRow.setString(2, "fixture-draw-request-" + row.segmentId());
                insertRow.setString(3, "0000000000000000000000000000000000000000000000000000000000000000");
                insertRow.setLong(4, row.version());
                insertRow.setLong(5, row.version() + 1);
                insertRow.setObject(6, row.documentId());
                insertRow.setObject(7, row.actorId());
                insertRow.executeUpdate();
            }
        }
    }

    private static UUID firstUserId(Connection connection) throws SQLException {
        try (PreparedStatement query = connection.prepareStatement("select id from users order by created_at limit 1");
             ResultSet result = query.executeQuery()) {
            if (!result.next()) {
                throw new SQLException("fixture requires at least one user row for created_by");
            }
            return result.getObject(1, UUID.class);
        }
    }
}
