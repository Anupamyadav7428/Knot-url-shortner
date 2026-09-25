package com.example.loadbalancer.dto;

public class LinkResponse {
    private final String shortUrl;
    private final String code;
    private final String originalUrl;
    private final long clicks;
    private final String createdAt;

    public LinkResponse(String shortUrl, String code, String originalUrl, long clicks, String createdAt) {
        this.shortUrl = shortUrl;
        this.code = code;
        this.originalUrl = originalUrl;
        this.clicks = clicks;
        this.createdAt = createdAt;
    }

    public String getShortUrl() {
        return shortUrl;
    }

    public String getCode() {
        return code;
    }

    public String getOriginalUrl() {
        return originalUrl;
    }

    public long getClicks() {
        return clicks;
    }

    public String getCreatedAt() {
        return createdAt;
    }
}
