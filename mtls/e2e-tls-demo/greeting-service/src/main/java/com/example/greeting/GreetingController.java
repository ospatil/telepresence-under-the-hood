package com.example.greeting;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
public class GreetingController {

    private final RestClient restClient;

    public GreetingController(RestClient restClient) {
        this.restClient = restClient;
    }

    public record Quote(String text, String source) {}
    public record Greeting(String message, String quote, String quoteSource) {}

    @GetMapping("/greeting")
    public Greeting greeting() {
        var quote = restClient.get()
                .uri("/quote")
                .retrieve()
                .body(Quote.class);
        return new Greeting(
                "Hello from greeting-service!",
                quote != null ? quote.text() : "unavailable",
                quote != null ? quote.source() : "unknown"
        );
    }
}
