package com.uten.imp.features.common.taskclaim;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface TaskClaimRepository extends JpaRepository<TaskClaim, UUID> {

    /** 某目标的未释放认领（至多一条，由部分唯一索引 uq_task_claim_active 保证）。 */
    Optional<TaskClaim> findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(
            String targetType, String targetKey);

    /** 全部未释放认领（装配列表/看板用；租约过期在内存里惰性判定）。 */
    List<TaskClaim> findAllByReleasedAtIsNull();

    /** 某类型的未释放认领（按类型列出处理中任务）。 */
    List<TaskClaim> findAllByTargetTypeAndReleasedAtIsNull(String targetType);

    /** 我处理中的事项。 */
    List<TaskClaim> findAllByClaimedByAndReleasedAtIsNullOrderByClaimedAtDesc(UUID claimedBy);
}
