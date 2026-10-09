package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.UUID;

/** 个人通知弹窗开关（V833/ADR-171）。 */
public interface NoticePopupPreferenceRepository extends JpaRepository<NoticePopupPreference, NoticePopupPreferenceId> {

    @Query(value = "SELECT source_event FROM notice_popup_preferences WHERE user_id = ?1 ORDER BY source_event",
            nativeQuery = true)
    List<String> findDisabledEvents(UUID userId);
}
