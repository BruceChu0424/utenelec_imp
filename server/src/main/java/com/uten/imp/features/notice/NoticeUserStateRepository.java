package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface NoticeUserStateRepository extends JpaRepository<NoticeUserState, NoticeUserStateId> {

    List<NoticeUserState> findByIdUserIdAndIdNoticeIdIn(
            UUID userId,
            List<UUID> noticeIds);

    @Modifying
    @Query(value = """
            INSERT INTO notice_user_states (notice_id, user_id, read_at)
            SELECT n.id, :userId, CURRENT_TIMESTAMP
            FROM notices n
            LEFT JOIN notice_user_states s
              ON s.notice_id = n.id AND s.user_id = :userId
            WHERE (
                    (n.audience_user_id IS NULL AND n.audience_scope = 'all')
                    OR n.audience_user_id = :userId
                    OR (n.audience_scope = 'selected' AND s.notice_id IS NOT NULL)
                  )
              AND (s.notice_id IS NULL OR (s.deleted_at IS NULL AND s.read_at IS NULL))
            ON CONFLICT (notice_id, user_id) DO UPDATE
            SET read_at = COALESCE(notice_user_states.read_at, EXCLUDED.read_at)
            WHERE notice_user_states.deleted_at IS NULL
            """, nativeQuery = true)
    int markAllVisibleRead(@Param("userId") UUID userId);
}
