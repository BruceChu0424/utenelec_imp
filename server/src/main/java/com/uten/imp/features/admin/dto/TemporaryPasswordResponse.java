package com.uten.imp.features.admin.dto;

/**
 * One-time response after an administrator resets an account password.
 *
 * <p>The plaintext is returned once and is never written to logs or storage.
 */
public record TemporaryPasswordResponse(String temporaryPassword) {}
