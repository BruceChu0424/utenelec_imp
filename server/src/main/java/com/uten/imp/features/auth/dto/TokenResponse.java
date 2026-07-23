package com.uten.imp.features.auth.dto;

import java.util.List;

public record TokenResponse(
        String accessToken,
        String refreshToken,
        long expiresIn,
        boolean mustChangePassword,
        UserProfile user
) {
    public record UserProfile(
            String id,
            String loginAccount,
            String name,
            String code,
            String department,
            String position,
            List<String> roles,
            List<String> permissions
    ) {}
}
