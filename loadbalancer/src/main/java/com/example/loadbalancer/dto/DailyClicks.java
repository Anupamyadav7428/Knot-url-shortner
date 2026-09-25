package com.example.loadbalancer.dto;

public class DailyClicks {
    private final String date;
    private final long clicks;

    public DailyClicks(String date, long clicks) {
        this.date = date;
        this.clicks = clicks;
    }

    public String getDate() {
        return date;
    }

    public long getClicks() {
        return clicks;
    }
}
