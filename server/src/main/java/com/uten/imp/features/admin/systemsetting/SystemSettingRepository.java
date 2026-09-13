package com.uten.imp.features.admin.systemsetting;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import jakarta.persistence.LockModeType;
import java.util.Collection;
import java.util.List;

public interface SystemSettingRepository extends JpaRepository<SystemSetting, String> {
    /** Deterministic lock order serializes overlapping administrative changes. */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select s from SystemSetting s where s.key in :keys order by s.key")
    List<SystemSetting> findAllForUpdate(@Param("keys") Collection<String> keys);
}
