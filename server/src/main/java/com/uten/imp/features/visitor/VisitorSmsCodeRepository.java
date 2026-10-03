package com.uten.imp.features.visitor;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.repository.query.Param;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

public interface VisitorSmsCodeRepository extends JpaRepository<VisitorSmsCode, UUID> {
    /** 某手机号最新一条未消费的验证码。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT c FROM VisitorSmsCode c WHERE c.phone=:phone AND c.consumedAt IS NULL AND c.deliveryResult<>'REJECTED' ORDER BY c.createdAt DESC LIMIT 1")
    Optional<VisitorSmsCode> findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(@Param("phone") String phone);

    /** 某手机号最新一条验证码（不限消费状态，用于发送间隔判断 M3）。 */
    @Query("SELECT c FROM VisitorSmsCode c WHERE c.phone=:phone AND c.deliveryResult<>'REJECTED' ORDER BY c.createdAt DESC LIMIT 1")
    Optional<VisitorSmsCode> findTopByPhoneOrderByCreatedAtDesc(@Param("phone") String phone);

    /** 当日发送条数（限流用）。 */
    @Query("SELECT count(c) FROM VisitorSmsCode c WHERE c.phone=:phone AND c.createdAt>:after AND c.deliveryResult<>'REJECTED'")
    long countByPhoneAndCreatedAtAfter(@Param("phone") String phone,@Param("after") OffsetDateTime after);

    @Modifying(clearAutomatically=true,flushAutomatically=true)
    @Query("UPDATE VisitorSmsCode c SET c.deliveryResult=:result,c.deliveryResultAt=CURRENT_TIMESTAMP,c.deliveryActor='sms_gateway',c.deliveryReason=:reason WHERE c.id=:id AND c.deliveryResult='OPEN_OR_UNKNOWN'")
    int recordDelivery(@Param("id") UUID id,@Param("result") String result,@Param("reason") String reason);
}
