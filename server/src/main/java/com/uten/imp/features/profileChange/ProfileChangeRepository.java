package com.uten.imp.features.profileChange;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ProfileChangeRepository extends JpaRepository<ProfileChangeRequest, UUID> {

    /** 按批次取所有行。 */
    List<ProfileChangeRequest> findByBatchId(UUID batchId);

    /** 按批次 + 状态取所有行（HR 审批时锁定批次）。 */
    List<ProfileChangeRequest> findByBatchIdAndStatus(UUID batchId, String status);

    /** HR 队列分页（按状态过滤）。 */
    Page<ProfileChangeRequest> findByStatusOrderBySubmittedAtDesc(String status, Pageable pageable);

    /** HR 队列全部（混合状态），按提交时间倒序。 */
    Page<ProfileChangeRequest> findAllByOrderBySubmittedAtDesc(Pageable pageable);

    /** 员工自查：分页按状态过滤。 */
    Page<ProfileChangeRequest> findByEmployeeIdAndStatusOrderBySubmittedAtDesc(
            UUID employeeId, String status, Pageable pageable);

    Page<ProfileChangeRequest> findByEmployeeIdOrderBySubmittedAtDesc(UUID employeeId, Pageable pageable);

    /** 员工自查：仅看自己。 */
    Page<ProfileChangeRequest> findBySubmittedByOrderBySubmittedAtDesc(UUID submittedBy, Pageable pageable);

    Page<ProfileChangeRequest> findBySubmittedByAndStatusOrderBySubmittedAtDesc(
            UUID submittedBy, String status, Pageable pageable);

    /** 幂等键查重（DB 唯一约束兜底）。 */
    Optional<ProfileChangeRequest> findByIdemKey(String idemKey);

    /** 同一员工同一字段，24h 内是否已有非终态记录（防骚扰 / 防重复）。 */
    @Query("""
        SELECT COUNT(p) FROM ProfileChangeRequest p
        WHERE p.employeeId = :employeeId
          AND p.fieldCode = :fieldCode
          AND p.status IN ('pending','approved','applied')
          AND p.submittedAt >= :since
        """)
    long countRecentActiveByField(@Param("employeeId") UUID employeeId,
                                  @Param("fieldCode") String fieldCode,
                                  @Param("since") java.time.OffsetDateTime since);

    /** 某员工待审计数（HR 详情页 Hero 后区块使用）。 */
    long countByEmployeeIdAndStatus(UUID employeeId, String status);

    /** 当前 HR 待办总计数（导航徽章使用）。 */
    long countByStatus(String status);
}