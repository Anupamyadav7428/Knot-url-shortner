package com.example.loadbalancer.service;

public class AliasTakenException extends RuntimeException {
    public AliasTakenException(String message) {
        super(message);
    }
}
