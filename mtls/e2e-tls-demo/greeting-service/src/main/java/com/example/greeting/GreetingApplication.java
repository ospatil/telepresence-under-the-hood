package com.example.greeting;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.context.annotation.Bean;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import javax.net.ssl.SSLContext;
import java.net.http.HttpClient;

@SpringBootApplication
public class GreetingApplication {

    public static void main(String[] args) {
        SpringApplication.run(GreetingApplication.class, args);
    }

    @Bean
    public RestClient restClient(SslBundles sslBundles) {
        SSLContext sslContext = sslBundles.getBundle("client").createSslContext();
        HttpClient httpClient = HttpClient.newBuilder().sslContext(sslContext).build();
        return RestClient.builder()
                .baseUrl("https://quote-service.quote-service-ns.svc.cluster.local:8443")
                .requestFactory(new JdkClientHttpRequestFactory(httpClient))
                .build();
    }
}
