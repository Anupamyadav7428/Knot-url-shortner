package com.example.loadbalancer.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.example.loadbalancer.dto.CachedLink;
import com.example.loadbalancer.dto.DailyClicks;
import com.example.loadbalancer.dto.LinkResponse;
import com.example.loadbalancer.entity.LinkClickEvent;
import com.example.loadbalancer.entity.UrlShortner;
import com.example.loadbalancer.repository.LinkClickEventRepository;
import com.example.loadbalancer.repository.ShortUrlRepository;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

@Service
public class ShortUrlService {

    private static final Logger log = LoggerFactory.getLogger(ShortUrlService.class);

    private static final String BASE62_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    private static final Pattern ALIAS_PATTERN = Pattern.compile("^[a-zA-Z0-9-_]{3,30}$");
    private static final String CACHE_KEY_PREFIX = "link:";
    private static final Duration CACHE_TTL = Duration.ofMinutes(30);

    private final ShortUrlRepository shortUrlRepository;
    private final LinkClickEventRepository linkClickEventRepository;
    private final RedisTemplate<String, CachedLink> redisTemplate;
    private final String baseUrl;

    public ShortUrlService(
            ShortUrlRepository shortUrlRepository,
            LinkClickEventRepository linkClickEventRepository,
            RedisTemplate<String, CachedLink> redisTemplate,
            @Value("${app.base-url}") String baseUrl) {
        this.shortUrlRepository = shortUrlRepository;
        this.linkClickEventRepository = linkClickEventRepository;
        this.redisTemplate = redisTemplate;
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl : baseUrl + "/";
    }

    public LinkResponse createShortUrl(String originalUrl, String alias, String ownerId) {
        if (originalUrl == null || originalUrl.isBlank()) {
            throw new IllegalArgumentException("URL is required.");
        }
        String normalizedUrl = originalUrl.trim();

        if (alias != null && !alias.isBlank()) {
            return createWithAlias(normalizedUrl, alias.trim(), ownerId);
        }

        // Reuse this owner's existing mapping for the same URL, instead of
        // inserting a duplicate row. Different owners always get their own row,
        // so one person's link never shows up in someone else's list.
        return shortUrlRepository.findFirstByOriginalUrlAndOwnerId(normalizedUrl, ownerId)
                .map(this::toResponse)
                .orElseGet(() -> {
                    UrlShortner urlShortner = new UrlShortner();
                    urlShortner.setOriginalUrl(normalizedUrl);
                    urlShortner.setCreatedAt(LocalDateTime.now());
                    urlShortner.setOwnerId(ownerId);
                    urlShortner = shortUrlRepository.save(urlShortner); // assigns the auto-increment id

                    // Encode the row's id as base62 for a short, TinyURL-style code (e.g. "b7", "1F3")
                    String code = encodeBase62(urlShortner.getId());
                    urlShortner.setShortUrl(code);
                    urlShortner = shortUrlRepository.save(urlShortner);

                    cachePut(code, urlShortner);
                    return toResponse(urlShortner);
                });
    }

    private LinkResponse createWithAlias(String originalUrl, String alias, String ownerId) {
        if (!ALIAS_PATTERN.matcher(alias).matches()) {
            throw new IllegalArgumentException(
                    "Alias must be 3-30 characters: letters, numbers, hyphens or underscores.");
        }

        return shortUrlRepository.findFirstByShortUrl(alias)
                .map(existing -> {
                    if (!existing.getOriginalUrl().equals(originalUrl) || !sameOwner(existing.getOwnerId(), ownerId)) {
                        throw new AliasTakenException("That alias is already taken.");
                    }
                    return toResponse(existing);
                })
                .orElseGet(() -> {
                    UrlShortner urlShortner = new UrlShortner();
                    urlShortner.setOriginalUrl(originalUrl);
                    urlShortner.setShortUrl(alias);
                    urlShortner.setCreatedAt(LocalDateTime.now());
                    urlShortner.setOwnerId(ownerId);
                    urlShortner = shortUrlRepository.save(urlShortner);
                    cachePut(alias, urlShortner);
                    return toResponse(urlShortner);
                });
    }

    @Transactional
    public String resolveOriginalUrl(String code) {
        Optional<CachedLink> cached = cacheGet(code);
        if (cached.isPresent()) {
            // The row could have been deleted since it was cached - incrementClickCount
            // tells us whether it's still really there before we trust the cached value.
            int updated = shortUrlRepository.incrementClickCount(code);
            if (updated == 0) {
                cacheEvict(code);
                return null;
            }
            linkClickEventRepository.save(new LinkClickEvent(code, LocalDateTime.now(), cached.get().ownerId()));
            return cached.get().originalUrl();
        }

        return shortUrlRepository.findFirstByShortUrl(code)
                .map(entity -> {
                    shortUrlRepository.incrementClickCount(code);
                    linkClickEventRepository.save(new LinkClickEvent(code, LocalDateTime.now(), entity.getOwnerId()));
                    cachePut(code, entity);
                    return entity.getOriginalUrl();
                })
                .orElse(null);
    }

    @Transactional(readOnly = true)
    public List<LinkResponse> listRecent(String ownerId) {
        return shortUrlRepository.findTop10ByOwnerIdOrderByIdDesc(ownerId).stream()
                .map(this::toResponse)
                .toList();
    }

    public boolean deleteByCode(String code, String ownerId) {
        return shortUrlRepository.findFirstByShortUrl(code)
                .filter(entity -> sameOwner(entity.getOwnerId(), ownerId))
                .map(entity -> {
                    shortUrlRepository.delete(entity);
                    cacheEvict(code);
                    return true;
                })
                .orElse(false);
    }

    @Transactional(readOnly = true)
    public List<DailyClicks> dailyClickCounts(String ownerId) {
        LocalDate today = LocalDate.now();
        LocalDate start = today.minusDays(6);

        List<LinkClickEvent> events =
                linkClickEventRepository.findByClickedAtGreaterThanEqualAndOwnerId(start.atStartOfDay(), ownerId);
        Map<LocalDate, Long> countsByDay = events.stream()
                .collect(Collectors.groupingBy(e -> e.getClickedAt().toLocalDate(), Collectors.counting()));

        List<DailyClicks> result = new ArrayList<>();
        for (int i = 0; i <= 6; i++) {
            LocalDate day = start.plusDays(i);
            result.add(new DailyClicks(day.toString(), countsByDay.getOrDefault(day, 0L)));
        }
        return result;
    }

    // The redirect path must keep working even if Redis is down or unreachable,
    // so every cache operation is best-effort: on any failure we log and fall
    // straight back through to MySQL instead of failing the request.

    private Optional<CachedLink> cacheGet(String code) {
        try {
            return Optional.ofNullable(redisTemplate.opsForValue().get(CACHE_KEY_PREFIX + code));
        } catch (Exception e) {
            log.warn("Redis cache read failed for code '{}', falling back to MySQL: {}", code, e.getMessage());
            return Optional.empty();
        }
    }

    private void cachePut(String code, UrlShortner entity) {
        try {
            redisTemplate.opsForValue().set(
                    CACHE_KEY_PREFIX + code,
                    new CachedLink(entity.getOriginalUrl(), entity.getOwnerId()),
                    CACHE_TTL);
        } catch (Exception e) {
            log.warn("Redis cache write failed for code '{}': {}", code, e.getMessage());
        }
    }

    private void cacheEvict(String code) {
        try {
            redisTemplate.delete(CACHE_KEY_PREFIX + code);
        } catch (Exception e) {
            log.warn("Redis cache evict failed for code '{}': {}", code, e.getMessage());
        }
    }

    private static boolean sameOwner(String a, String b) {
        return a != null && a.equals(b);
    }

    private LinkResponse toResponse(UrlShortner entity) {
        String createdAt = entity.getCreatedAt() != null
                ? entity.getCreatedAt().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME)
                : null;
        return new LinkResponse(
                baseUrl + entity.getShortUrl(),
                entity.getShortUrl(),
                entity.getOriginalUrl(),
                entity.getClickCount(),
                createdAt);
    }

    private static String encodeBase62(long value) {
        if (value == 0) {
            return String.valueOf(BASE62_ALPHABET.charAt(0));
        }
        StringBuilder sb = new StringBuilder();
        while (value > 0) {
            sb.append(BASE62_ALPHABET.charAt((int) (value % 62)));
            value /= 62;
        }
        return sb.reverse().toString();
    }
}
