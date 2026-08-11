package com.uten.imp.security;

import com.uten.imp.features.auth.PermissionResolver;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StaffAuthorityResolverTest {

    @Test
    void cachesOnlyTheSameVersionedAuthorizationShape() {
        PermissionResolver delegate = mock(PermissionResolver.class);
        AtomicLong clock = new AtomicLong();
        StaffAuthorityResolver resolver = new StaffAuthorityResolver(
                delegate, clock::get, Duration.ofSeconds(30), 8);
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        PermissionResolver.AuthorizationSnapshot snapshot = snapshot("employee:view");
        when(delegate.authorizationSnapshot(userId, employeeId, false)).thenReturn(snapshot);

        assertSame(snapshot, resolver.resolve(userId, employeeId, false, 7, 11));
        clock.addAndGet(Duration.ofSeconds(5).toNanos());
        assertSame(snapshot, resolver.resolve(userId, employeeId, false, 7, 11));

        verify(delegate).authorizationSnapshot(userId, employeeId, false);
    }

    @Test
    void authVersionOrEpochChangeReResolvesImmediately() {
        PermissionResolver delegate = mock(PermissionResolver.class);
        StaffAuthorityResolver resolver = new StaffAuthorityResolver(
                delegate, () -> 0L, Duration.ofSeconds(30), 8);
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(delegate.authorizationSnapshot(userId, employeeId, false))
                .thenReturn(snapshot("employee:view"), snapshot("employee:edit"), snapshot("audit:view"));

        resolver.resolve(userId, employeeId, false, 7, 11);
        resolver.resolve(userId, employeeId, false, 8, 11);
        resolver.resolve(userId, employeeId, false, 8, 12);

        verify(delegate, times(3)).authorizationSnapshot(userId, employeeId, false);
    }

    @Test
    void expiredSnapshotIsNotReused() {
        PermissionResolver delegate = mock(PermissionResolver.class);
        AtomicLong clock = new AtomicLong();
        StaffAuthorityResolver resolver = new StaffAuthorityResolver(
                delegate, clock::get, Duration.ofSeconds(1), 8);
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(delegate.authorizationSnapshot(userId, employeeId, false))
                .thenReturn(snapshot("employee:view"));

        resolver.resolve(userId, employeeId, false, 7, 11);
        clock.set(Duration.ofSeconds(1).toNanos());
        resolver.resolve(userId, employeeId, false, 7, 11);

        verify(delegate, times(2)).authorizationSnapshot(userId, employeeId, false);
    }

    @Test
    void cacheRemainsBounded() {
        PermissionResolver delegate = mock(PermissionResolver.class);
        StaffAuthorityResolver resolver = new StaffAuthorityResolver(
                delegate, () -> 0L, Duration.ofSeconds(30), 2);
        UUID employeeId = UUID.randomUUID();
        when(delegate.authorizationSnapshot(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.eq(employeeId),
                org.mockito.ArgumentMatchers.eq(false)))
                .thenReturn(snapshot("employee:view"));

        resolver.resolve(UUID.randomUUID(), employeeId, false, 1, 1);
        resolver.resolve(UUID.randomUUID(), employeeId, false, 1, 1);
        resolver.resolve(UUID.randomUUID(), employeeId, false, 1, 1);

        assertEquals(2, resolver.cacheSize());
    }

    private PermissionResolver.AuthorizationSnapshot snapshot(String permission) {
        return new PermissionResolver.AuthorizationSnapshot(
                Set.of("employee"),
                Set.of(permission));
    }
}
