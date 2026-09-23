package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** security-03: 密码哈希的进程级并发闸门, 满了在限定时间内快速返回 503 而不是无限排队。 */
class BoundedPasswordEncoderTest {

    /** 模拟一次很慢的哈希 (阻塞到测试放行), 用来把名额占满。 */
    private static final class BlockingEncoder implements PasswordEncoder {
        private final CountDownLatch entered;
        private final CountDownLatch release = new CountDownLatch(1);

        private BlockingEncoder(int expectedEntrants) {
            this.entered = new CountDownLatch(expectedEntrants);
        }

        @Override
        public String encode(CharSequence rawPassword) {
            block();
            return "hash:" + rawPassword;
        }

        @Override
        public boolean matches(CharSequence rawPassword, String encodedPassword) {
            block();
            return encodedPassword.equals("hash:" + rawPassword);
        }

        private void block() {
            entered.countDown();
            try {
                release.await(10, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    @Test
    void callsBeyondThePermitsFailFastWithServiceBusyInsteadOfQueueingForever() throws Exception {
        BlockingEncoder slow = new BlockingEncoder(2);
        BoundedPasswordEncoder bounded = new BoundedPasswordEncoder(slow, 2, 200);
        ExecutorService pool = Executors.newFixedThreadPool(2);
        try {
            Future<Boolean> first = pool.submit(() -> bounded.matches("a", "hash:a"));
            Future<Boolean> second = pool.submit(() -> bounded.matches("b", "hash:b"));
            assertTrue(slow.entered.await(5, TimeUnit.SECONDS), "两个名额都已被占用");
            assertEquals(0, bounded.availablePermits());

            long started = System.nanoTime();
            ApiException busy = assertThrows(ApiException.class, () -> bounded.matches("c", "hash:c"));
            long waitedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);

            assertEquals(ErrorCode.AUTH_BUSY, busy.getCode());
            assertEquals(503, busy.getCode().getHttpStatus());
            assertTrue(waitedMillis < 2_000, "排队不超过设定的等待上限: " + waitedMillis + "ms");

            slow.release.countDown();
            assertTrue(first.get(5, TimeUnit.SECONDS));
            assertTrue(second.get(5, TimeUnit.SECONDS));
            assertEquals(2, bounded.availablePermits(), "名额在 finally 里归还");
            assertTrue(bounded.matches("c", "hash:c"), "释放后恢复正常");
        } finally {
            slow.release.countDown();
            pool.shutdownNow();
        }
    }

    @Test
    void encodeGoesThroughTheSameGateAndReleasesOnFailure() {
        PasswordEncoder failing = new PasswordEncoder() {
            @Override
            public String encode(CharSequence rawPassword) {
                throw new IllegalStateException("hash failure");
            }

            @Override
            public boolean matches(CharSequence rawPassword, String encodedPassword) {
                return false;
            }
        };
        BoundedPasswordEncoder bounded = new BoundedPasswordEncoder(failing, 1, 100);

        assertThrows(IllegalStateException.class, () -> bounded.encode("x"));
        assertEquals(1, bounded.availablePermits());
    }

    @Test
    void rejectsNonPositivePermits() {
        assertThrows(IllegalArgumentException.class,
                () -> new BoundedPasswordEncoder(new BlockingEncoder(0), 0, 100));
    }
}
