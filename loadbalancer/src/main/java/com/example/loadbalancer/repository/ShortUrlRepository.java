package com.example.loadbalancer.repository;
import com.example.loadbalancer.entity.UrlShortner;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;

public interface ShortUrlRepository extends JpaRepository<UrlShortner, Long> {

    Optional<UrlShortner> findFirstByShortUrl(String shortUrl);

    Optional<UrlShortner> findFirstByOriginalUrlAndOwnerId(String originalUrl, String ownerId);

    List<UrlShortner> findTop10ByOwnerIdOrderByIdDesc(String ownerId);

    @Modifying
    @Transactional
    @Query("UPDATE UrlShortner u SET u.clickCount = u.clickCount + 1 WHERE u.shortUrl = :code")
    int incrementClickCount(@Param("code") String code);
}
