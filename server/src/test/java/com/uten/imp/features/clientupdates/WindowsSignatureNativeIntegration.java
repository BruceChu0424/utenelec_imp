package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.UUID;

/** Explicit Linux/native crypto companion; synthetic public test CA is passed as a file, never installed. */
public final class WindowsSignatureNativeIntegration {
    private WindowsSignatureNativeIntegration() { }
    public static void main(String[] args) throws Exception {
        Path evidence = Path.of(args[0]);
        String pin = Files.readString(evidence.resolve("test-only-publisher-sha256.txt")).strip();
        var release = new ClientReleaseDto.Release(UUID.randomUUID(), "windows", "x64", "2.5.45", 2545,
                "test-only crypto fixture", false, "test-only.exe", "0".repeat(64), null, 0,
                "windows_setup", null, "", "DRAFT", Instant.now(), null, "installer", "flutter");
        int checks = 0;
        for (String name : new String[] { "crypto-fixture", "unsigned", "tampered", "no-timestamp" }) {
            var verifier = new WindowsPublisherSignatures(settings(args[1], evidence, pin, "valid"));
            boolean accepted;
            try { verifier.inspect(evidence.resolve("test-only-" + name + ".exe"), release); accepted = true; }
            catch (ApiException rejected) { accepted = false; }
            if (accepted != "crypto-fixture".equals(name)) throw new AssertionError("Native Java verification result differs: " + name);
            checks++;
        }
        for (String trust : new String[] { "revoked", "expired" }) {
            try {
                new WindowsPublisherSignatures(settings(args[1], evidence, pin, trust)).inspect(evidence.resolve("test-only-crypto-fixture.exe"), release);
                throw new AssertionError("Unusable revocation state accepted: " + trust);
            } catch (ApiException expected) { checks++; }
        }
        try {
            new WindowsPublisherSignatures(settings(args[1], evidence, "00".repeat(32), "valid"))
                    .inspect(evidence.resolve("test-only-crypto-fixture.exe"), release);
            throw new AssertionError("Wrong company certificate accepted");
        } catch (ApiException expected) { checks++; }
        var runtime = new ClientReleaseDto.Release(UUID.randomUUID(), "windows", "x64", "2.5.45", 2545,
                "test-only crypto binding", false, "test-only.zip", "0".repeat(64), null, 0,
                "windows_wpf_archive", null, "", "DRAFT", Instant.now(), null, "update", "wpf_legacy");
        new WindowsPublisherSignatures(settings(args[1], evidence, pin, "valid"))
                .inspect(evidence.resolve("test-only-bound-runtime.zip"), runtime);
        checks++;
        try {
            new WindowsPublisherSignatures(settings(args[1], evidence, pin, "valid"))
                    .inspect(evidence.resolve("test-only-replaced-runtime.zip"), runtime);
            throw new AssertionError("Signed launcher authorized changed non-PE runtime bytes");
        } catch (ApiException expected) { checks++; }
        System.out.println("Native Java signature checks passed: " + checks);
    }

    private static ClientUpdateProperties settings(String tool, Path evidence, String pin, String trust) {
        var settings = new ClientUpdateProperties();
        settings.setWindowsPublisherSha256(pin); settings.setWindowsSignatureVerifier(tool);
        settings.setWindowsSignatureCaFile(evidence.resolve("test-only-root.pem").toString());
        settings.setWindowsSignatureTsaCaFile(evidence.resolve("test-only-root.pem").toString());
        settings.setWindowsSignatureCrlFile(evidence.resolve("test-only-" + trust + ".crl.pem").toString());
        settings.setWindowsSignatureTsaCrlFile(evidence.resolve("test-only-" + trust + ".crl.pem").toString());
        return settings;
    }
}
