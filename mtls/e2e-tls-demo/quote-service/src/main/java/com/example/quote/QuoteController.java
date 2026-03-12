package com.example.quote;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

@RestController
public class QuoteController {

    private static final List<String> QUOTES = List.of(
            "The only way to do great work is to love what you do.",
            "Innovation distinguishes between a leader and a follower.",
            "Stay hungry, stay foolish.",
            "Simplicity is the ultimate sophistication."
    );

    public record Quote(String text, String source) {}

    @GetMapping("/quote")
    public Quote quote() {
        var text = QUOTES.get(ThreadLocalRandom.current().nextInt(QUOTES.size()));
        return new Quote(text, "quote-service");
    }
}
