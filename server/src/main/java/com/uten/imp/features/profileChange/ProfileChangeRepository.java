package com.uten.imp.features.profilechange;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.Lock;
import jakarta.persistence.LockModeType;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ProfileChangeRepository extends JpaRepository<ProfileChangeRequest, UUID> {

    // The UI reviews one batch, while the storage keeps one row per changed
    // field. Page/count batches before loading their complete field lists.
    // Aggregate priority matches ProfileChangeMapper.aggregateStatus.
    String BATCH_QUERY = """
        SELECT p.batch_id
        FROM profile_change_requests p
        LEFT JOIN employees e ON e.id = p.employee_id
        WHERE (CAST(:submittedBy AS uuid) IS NULL OR p.submitted_by = CAST(:submittedBy AS uuid))
          AND (CAST(:employeeId AS uuid) IS NULL OR p.employee_id = CAST(:employeeId AS uuid))
          AND (CAST(:departmentId AS uuid) IS NULL OR e.department_id = CAST(:departmentId AS uuid))
        GROUP BY p.batch_id
        HAVING (CAST(:status AS text) IS NULL OR
          MAX(CASE p.status WHEN 'pending' THEN 5 WHEN 'applied' THEN 4 WHEN 'approved' THEN 3
            WHEN 'rejected' THEN 2 WHEN 'cancelled' THEN 1 ELSE 0 END) =
          CASE CAST(:status AS text) WHEN 'pending' THEN 5 WHEN 'applied' THEN 4 WHEN 'approved' THEN 3
            WHEN 'rejected' THEN 2 WHEN 'cancelled' THEN 1 ELSE -1 END)
        """;

    @Query(value = BATCH_QUERY + " ORDER BY MAX(p.submitted_at) DESC, p.batch_id DESC",
            countQuery = "SELECT COUNT(*) FROM (" + BATCH_QUERY + ") batches",
            nativeQuery = true)
    Page<UUID> findBatchIds(@Param("status") String status,
            @Param("submittedBy") UUID submittedBy,
            @Param("employeeId") UUID employeeId,
            @Param("departmentId") UUID departmentId,
            Pageable pageable);

    @Query(value = "SELECT COUNT(*) FROM (" + BATCH_QUERY + ") batches", nativeQuery = true)
    long countBatches(@Param("status") String status,
            @Param("submittedBy") UUID submittedBy,
            @Param("employeeId") UUID employeeId,
            @Param("departmentId") UUID departmentId);

    @Query("""
        SELECT p FROM ProfileChangeRequest p
        WHERE p.batchId IN :batchIds
          AND (:submittedBy IS NULL OR p.submittedBy = :submittedBy)
        ORDER BY p.submittedAt DESC, p.id DESC
        """)
    List<ProfileChangeRequest> findBatchRows(@Param("batchIds") List<UUID> batchIds,
            @Param("submittedBy") UUID submittedBy);

    /** 按批次取所有行。 */
    List<ProfileChangeRequest> findByBatchId(UUID batchId);

    /** 按批次 + 状态取所有行（HR 审批时锁定批次）。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT p FROM ProfileChangeRequest p WHERE p.batchId = :batchId AND p.status = :status ORDER BY p.id")
    List<ProfileChangeRequest> findByBatchIdAndStatus(@Param("batchId") UUID batchId, @Param("status") String status);

    /**
     * 某状态下按员工所属部门聚合的批次数（表头「部门」筛选桶）：
     * 返回 [department_id, department_name, batch_count]，按部门名排序。
     */
    @Query(value = """
        SELECT e.department_id, d.name, COUNT(DISTINCT p.batch_id)
        FROM profile_change_requests p
        JOIN employees e ON e.id = p.employee_id
        JOIN departments d ON d.id = e.department_id
        WHERE p.batch_id IN (
          SELECT p.batch_id FROM profile_change_requests p GROUP BY p.batch_id
          HAVING MAX(CASE p.status WHEN 'pending' THEN 5 WHEN 'applied' THEN 4 WHEN 'approved' THEN 3
            WHEN 'rejected' THEN 2 WHEN 'cancelled' THEN 1 ELSE 0 END) =
          CASE CAST(:status AS text) WHEN 'pending' THEN 5 WHEN 'applied' THEN 4 WHEN 'approved' THEN 3
            WHEN 'rejected' THEN 2 WHEN 'cancelled' THEN 1 ELSE -1 END)
        GROUP BY e.department_id, d.name
        ORDER BY d.name
        """, nativeQuery = true)
    List<Object[]> countBatchesByDepartment(@Param("status") String status);

    /** 幂等键查重（DB 唯一约束兜底）。 */
    Optional<ProfileChangeRequest> findByIdemKey(String idemKey);
    List<ProfileChangeRequest> findByIdemKeyStartingWith(String prefix);

    /** Claims a not-yet-existing submission/batch without adding a new ledger. */
    @Query(value = "SELECT COUNT(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(CAST(:key AS text), 285))) acquired",
            nativeQuery = true)
    long lockSubmission(@Param("key") String key);

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

    /** 某员工某状态的全部记录（离职时批量自动驳回在途申请）。 */
    List<ProfileChangeRequest> findByEmployeeIdAndStatus(UUID employeeId, String status);

}
