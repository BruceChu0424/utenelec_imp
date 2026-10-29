package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Path;
import java.time.Instant;
import java.util.UUID;

/** Explicit read-only same-producer fixture entry, never starts an uploaded assembly or a server. */
public final class WpfProducerPackageIntegration {
    private WpfProducerPackageIntegration() { }
    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 2 || !WpfPackageContract.ARCHITECTURES.contains(arguments[1]))
            throw new IllegalArgumentException("Expected temporary producer fixture and architecture");
        Path file = Path.of(arguments[0]).toAbsolutePath().normalize();
        Path root = file.getParent();
        if (!"producer.zip".equals(file.getFileName().toString())
                || !root.getFileName().toString().startsWith("uten-wpf-producer-link-")
                || !root.getParent().equals(Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath().normalize()))
            throw new IllegalArgumentException("Only the exact random integration fixture is accepted");
        var release = new ClientReleaseDto.Release(UUID.randomUUID(), "windows", arguments[1], "2.5.35", 2535, "", false,
                "producer.zip", null, null, java.nio.file.Files.size(file), "windows_wpf_archive", null, null,
                "DRAFT", Instant.now(), null, "update", "wpf_legacy");
        new ClientPackageInspector(new ObjectMapper()).inspect(file, release);
        System.out.println("PASS same-producer WPF package " + arguments[1]);
    }
}
