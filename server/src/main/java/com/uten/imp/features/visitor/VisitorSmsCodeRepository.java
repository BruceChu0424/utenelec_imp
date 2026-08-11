package com.uten.imp.features.visitor;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

public interface VisitorSmsCodeRepository extends JpaRepository<VisitorSmsCode, UUID> {
    /** 某手机号最新一条未消费的验证码。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<VisitorSmsCode> findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(String phone);

    /** 某手机号最新一条验证码（不限消费状态，用于发送间隔判断 M3）。 */
    Optional<VisitorSmsCode> findTopByPhoneOrderByCreatedAtDesc(String phone);

    /** 当日发送条数（限流用）。 */
    long countByPhoneAndCreatedAtAfter(String phone, OffsetDateTime after);
}
