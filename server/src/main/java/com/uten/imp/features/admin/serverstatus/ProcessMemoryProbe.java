package com.uten.imp.features.admin.serverstatus;

import java.nio.file.Files;
import java.nio.file.Path;

/** Actual resident bytes, never committed virtual address space or Java heap. */
final class ProcessMemoryProbe {
    private ProcessMemoryProbe() {}
    static Long residentBytes() {
        if (!System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT).contains("linux")) return null;
        try { return linuxResidentBytes(Files.readString(Path.of("/proc/self/status"))); }
        catch (Exception unavailable) { return null; }
    }
    static Long linuxResidentBytes(String status) {
        try {
            Long result = null;
            for (String line : status.lines().toList()) {
                if (!line.startsWith("VmRSS:")) continue;
                if (result != null) return null;
                String[] columns = line.trim().split("\\s+");
                if (columns.length != 3 || !"kB".equals(columns[2])) return null;
                long bytes = Math.multiplyExact(Long.parseLong(columns[1]), 1024L);
                if (bytes <= 0) return null;
                result = bytes;
            }
            return result;
        } catch (NumberFormatException | ArithmeticException malformed) { return null; }
    }
}
