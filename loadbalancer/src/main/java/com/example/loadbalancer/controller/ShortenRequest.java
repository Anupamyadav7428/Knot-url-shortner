package com.example.loadbalancer.controller;

import com.fasterxml.jackson.annotation.JsonAlias;

public class ShortenRequest {
    @JsonAlias("url")
    private String originalUrl;
    private String alias;

    public String getOriginalUrl() {
        return originalUrl;
    }

    public void setOriginalUrl(String originalUrl) {
        this.originalUrl = originalUrl;
    }

    public String getAlias() {
        return alias;
    }

    public void setAlias(String alias) {
        this.alias = alias;
    }
}
