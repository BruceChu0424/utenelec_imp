package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface NoticeUserStateRepository extends JpaRepository<NoticeUserState, NoticeUserStateId> {

    /** 当前用户全部状态行（已读/删除都在服务层归并；无记录 = 未读未删）。 */
    List<NoticeUserState> findByIdUserId(UUID userId);
}
