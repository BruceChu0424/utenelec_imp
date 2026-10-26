package com.uten.imp.common.export;
import org.junit.jupiter.api.Test;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;

class ExportOperationCheckpointTest {
    @Test void longSourcePassesUseOneThrottledCallbackAndRestoreAnOuterScope() {
        var outer=new AtomicInteger();var inner=new AtomicInteger();
        var clock=new java.util.concurrent.atomic.AtomicLong();
        try(var first=ExportOperationCheckpoint.open(outer::incrementAndGet,clock::get)) {
            ExportOperationCheckpoint.check();
            for(int index=0;index<1000;index++)ExportOperationCheckpoint.check();
            assertEquals(1,outer.get());
            try(var second=ExportOperationCheckpoint.open(inner::incrementAndGet,clock::get)){ExportOperationCheckpoint.check();}
            ExportOperationCheckpoint.check();assertEquals(1,inner.get());assertEquals(1,outer.get());
            clock.set(1_000_000_000L);ExportOperationCheckpoint.check();assertEquals(2,outer.get());
        }
        ExportOperationCheckpoint.check();assertEquals(2,outer.get());
    }
    @Test void aRevokedSourceStopsAndNeverSwallowsTheAuthoritativeCallbackFailure() {
        var error=new IllegalStateException("source cancelled or revoked");
        try(var operation=ExportOperationCheckpoint.open(()->{throw error;})) {
            assertSame(error,assertThrows(IllegalStateException.class,ExportOperationCheckpoint::check));
        }
        assertDoesNotThrow(ExportOperationCheckpoint::check);
    }
}
