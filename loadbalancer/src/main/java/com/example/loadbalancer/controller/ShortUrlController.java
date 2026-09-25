package com.example.loadbalancer.controller;

import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RestController;

import com.example.loadbalancer.dto.DailyClicks;
import com.example.loadbalancer.dto.ErrorResponse;
import com.example.loadbalancer.dto.LinkResponse;
import com.example.loadbalancer.service.AliasTakenException;
import com.example.loadbalancer.service.ShortUrlService;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;

import java.util.List;

@RestController
public class ShortUrlController {

    // Identifies the caller so /api/links and the analytics chart only ever
    // show the requesting browser's own links, never anyone else's. There's no
    // login system, so the frontend generates and persists a random id per
    // browser and sends it on every request via this header.
    private static final String CLIENT_ID_HEADER = "X-Client-Id";

    private final ShortUrlService shortUrlService;
    public ShortUrlController(ShortUrlService shortUrlService) {
        this.shortUrlService = shortUrlService;
    }

    // Endpoint to create a short URL - expects JSON body: {"originalUrl": "https://...", "alias": "optional"}
    @PostMapping("/shorten")
    public ResponseEntity<?> createShortUrl(
            @RequestBody ShortenRequest request,
            @RequestHeader(value = CLIENT_ID_HEADER, required = false) String clientId) {
        try {
            LinkResponse response = shortUrlService.createShortUrl(request.getOriginalUrl(), request.getAlias(), clientId);
            return ResponseEntity.ok(response);
        } catch (AliasTakenException e) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(new ErrorResponse(e.getMessage()));
        } catch (IllegalArgumentException e) {
            return ResponseEntity.badRequest().body(new ErrorResponse(e.getMessage()));
        }
    }

    // Endpoint to redirect a short code to its original URL - open to anyone with the link
    @GetMapping("/{code}")
    public ResponseEntity<Void> redirectToOriginal(@PathVariable String code) {
        String originalUrl = shortUrlService.resolveOriginalUrl(code);
        if (originalUrl == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.status(HttpStatus.FOUND)
                .header(HttpHeaders.LOCATION, originalUrl)
                .build();
    }

    // Endpoint to list the requesting browser's own recently created links, with their real click counts
    @GetMapping("/api/links")
    public List<LinkResponse> listLinks(@RequestHeader(value = CLIENT_ID_HEADER, required = false) String clientId) {
        return shortUrlService.listRecent(clientId);
    }

    // Endpoint to delete a link - only the owning browser can delete its own link
    @DeleteMapping("/api/links/{code}")
    public ResponseEntity<Void> deleteLink(
            @PathVariable String code,
            @RequestHeader(value = CLIENT_ID_HEADER, required = false) String clientId) {
        boolean deleted = shortUrlService.deleteByCode(code, clientId);
        return deleted ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
    }

    // Endpoint returning the requesting browser's own click totals for each of the last 7 days
    @GetMapping("/api/analytics/daily")
    public List<DailyClicks> dailyClicks(@RequestHeader(value = CLIENT_ID_HEADER, required = false) String clientId) {
        return shortUrlService.dailyClickCounts(clientId);
    }
}
