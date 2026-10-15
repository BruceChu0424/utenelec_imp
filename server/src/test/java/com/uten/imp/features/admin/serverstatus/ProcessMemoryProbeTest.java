package com.uten.imp.features.admin.serverstatus;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ProcessMemoryProbeTest {
    @Test void residentIsVmRssAndNeverVirtualOrHeap() {
        assertThat(ProcessMemoryProbe.linuxResidentBytes("VmSize: 990000 kB\nVmRSS: 12345 kB\nRssAnon: 4000 kB\n"))
                .isEqualTo(12345L * 1024);
        assertThat(ProcessMemoryProbe.linuxResidentBytes("VmSize: 990000 kB\n")).isNull();
    }
    @Test void unavailableMalformedNegativeDuplicateAndOverflowAreUnknown() {
        for (String value : new String[]{"", "VmRSS: -1 kB", "VmRSS: 0 kB", "VmRSS: 15 MB",
                "VmRSS: 9223372036854775807 kB", "VmRSS: 10 kB\nVmRSS: 20 kB"})
            assertThat(ProcessMemoryProbe.linuxResidentBytes(value)).as(value).isNull();
    }
}
