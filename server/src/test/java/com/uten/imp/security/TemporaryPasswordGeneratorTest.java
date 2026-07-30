package com.uten.imp.security;

import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TemporaryPasswordGeneratorTest {

    private final TemporaryPasswordGenerator generator =
            new TemporaryPasswordGenerator();

    @Test
    void generatesHighEntropyPasswordsWithEveryRequiredCharacterClass() {
        Set<String> generated = new HashSet<>();

        for (int index = 0; index < 100; index++) {
            String password = generator.generate();
            assertEquals(20, password.length());
            assertTrue(password.chars().anyMatch(Character::isUpperCase));
            assertTrue(password.chars().anyMatch(Character::isLowerCase));
            assertTrue(password.chars().anyMatch(Character::isDigit));
            assertTrue(password.chars().anyMatch(
                    character -> "!@#$%*-_=+".indexOf(character) >= 0));
            generated.add(password);
        }

        assertEquals(100, generated.size());
    }
}
