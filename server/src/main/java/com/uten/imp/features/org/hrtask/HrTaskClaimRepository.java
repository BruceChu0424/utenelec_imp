package com.uten.imp.features.org.hrtask;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface HrTaskClaimRepository extends JpaRepository<HrTaskClaim, UUID> {
    @org.springframework.data.jpa.repository.Query(value = """
            SELECT EXISTS (SELECT 1 FROM notice_celebration_subjects subject
              JOIN notices notice ON notice.id = subject.notice_id
              WHERE subject.employee_id = :employeeId AND notice.type = :type
                AND notice.published_at >= make_date(:year, 1, 1) AT TIME ZONE 'Asia/Shanghai')
            """, nativeQuery = true)
    boolean celebrationPublished(@org.springframework.data.repository.query.Param("employeeId") UUID employeeId,
            @org.springframework.data.repository.query.Param("type") String type,
            @org.springframework.data.repository.query.Param("year") int year);

    /** 某任务的未释放认领（至多一条，由部分唯一索引保证）。 */
    Optional<HrTaskClaim> findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(
            String taskType, UUID employeeId);

    /** 全部未释放认领（summary 一次性装配；租约过期在内存里惰性判定）。 */
    List<HrTaskClaim> findAllByReleasedAtIsNull();

    /** 我处理中的事项。 */
    List<HrTaskClaim> findAllByClaimedByAndReleasedAtIsNullOrderByClaimedAtDesc(UUID claimedBy);
}
