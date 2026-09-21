package com.uten.imp.features.visitor;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface VisitorApplicationRepository
        extends JpaRepository<VisitorApplication, UUID>, JpaSpecificationExecutor<VisitorApplication> {
    Optional<VisitorApplication> findByPasscode(String passcode);

    /**
     * HR 审批队列两档计数(ADR-100)，一次扫描出两个数：
     * [0] pending = 等 HR 动手，与待审列表默认段同一状态集；
     * [1] ongoing = 已批准、访客还没来核验的在途来访。
     *
     * <p>计划来访日已过的不算在途：过期申请不会再有人来核验，挂进黄数字只会一直涨。
     * 外层 WHERE 只圈这三个状态，走 status 索引。
     */
    @Query(nativeQuery = true, value = """
            SELECT COUNT(*) FILTER (WHERE v.status IN ('pending', 'hostReviewing')),
                   COUNT(*) FILTER (WHERE v.status = 'approved'
                                      AND v.planned_visit_at >= :notBefore)
            FROM visitor_applications v
            WHERE v.is_deleted = false
              AND v.status IN ('pending', 'hostReviewing', 'approved')
            """)
    List<Object[]> countApprovalQueues(@Param("notBefore") OffsetDateTime notBefore);

    /**
     * 被访人两档计数(ADR-100)，一次扫描出两个数：
     * [0] pending = 待我确认接待，与「我作为接待人」列表默认段同一条件；
     * [1] ongoing = 我已确认、这趟来访还没走完(HR 审批中 + 已通过待来访)。
     *
     * <p>ongoing 只认 host_confirmed = true：HR 越过接待人直接批的单子，接待人从没动过手，
     * 不算「我手上在跑的活」。同样按计划来访日收口，过期的不再计入。
     */
    @Query(nativeQuery = true, value = """
            SELECT COUNT(*) FILTER (WHERE v.status = 'hostReviewing'),
                   COUNT(*) FILTER (WHERE v.host_confirmed = true
                                      AND v.status IN ('pending', 'approved')
                                      AND v.planned_visit_at >= :notBefore)
            FROM visitor_applications v
            WHERE v.is_deleted = false
              AND v.host_employee_id = :hostEmployeeId
              AND v.status IN ('pending', 'hostReviewing', 'approved')
            """)
    List<Object[]> countHostQueues(@Param("hostEmployeeId") UUID hostEmployeeId,
                                   @Param("notBefore") OffsetDateTime notBefore);

    interface ApplicationIdentity {
        UUID getVisitorAccountId();
    }

    // Closed projection avoids caching an unlocked application before its row lock.
    Optional<ApplicationIdentity> findIdentityById(UUID id);

    /** M2：悲观锁查询（SELECT ... FOR UPDATE），防 checkIn 并发重复签到。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<VisitorApplication> findAndLockById(UUID id);
}
