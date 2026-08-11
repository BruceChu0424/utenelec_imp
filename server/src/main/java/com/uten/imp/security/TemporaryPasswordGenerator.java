package com.uten.imp.security;

import org.springframework.stereotype.Component;

import java.security.SecureRandom;

/**
 * Generates a one-time-display temporary password for account recovery.
 *
 * <p>The generated value is never persisted in plaintext.  It contains at
 * least one character from every password class and is immediately paired with
 * {@code mustChangePassword=true} by the account support service.
 */
@Component
public class TemporaryPasswordGenerator {

    private static final String UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ";
    private static final String LOWER = "abcdefghijkmnopqrstuvwxyz";
    private static final String DIGITS = "23456789";
    private static final String SYMBOLS = "!@#$%*-_=+";
    private static final String ALL = UPPER + LOWER + DIGITS + SYMBOLS;
    private static final int LENGTH = 20;

    private final SecureRandom random = new SecureRandom();

    public String generate() {
        char[] value = new char[LENGTH];
        value[0] = pick(UPPER);
        value[1] = pick(LOWER);
        value[2] = pick(DIGITS);
        value[3] = pick(SYMBOLS);
        for (int i = 4; i < value.length; i++) {
            value[i] = pick(ALL);
        }
        for (int i = value.length - 1; i > 0; i--) {
            int j = random.nextInt(i + 1);
            char tmp = value[i];
            value[i] = value[j];
            value[j] = tmp;
        }
        return new String(value);
    }

    private char pick(String alphabet) {
        return alphabet.charAt(random.nextInt(alphabet.length()));
    }
}
