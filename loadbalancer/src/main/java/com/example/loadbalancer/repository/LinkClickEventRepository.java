package com.example.loadbalancer.repository;

import com.example.loadbalancer.entity.LinkClickEvent;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.LocalDateTime;
import java.util.List;

public interface LinkClickEventRepository extends JpaRepository<LinkClickEvent, Long> {

    List<LinkClickEvent> findByClickedAtGreaterThanEqualAndOwnerId(LocalDateTime since, String ownerId);
}
