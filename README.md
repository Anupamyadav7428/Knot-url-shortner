# Knot — URL Shortener behind an Nginx Load Balancer

A TinyURL-style URL shortener built to demonstrate horizontal scaling: **four Spring Boot instances** sit behind an **Nginx load balancer** with rate limiting and automatic failover, backed by **MySQL** for storage and **Redis** as a read-through cache. An **Angular** frontend lets users create short links, see their recent links, and view a 7-day click chart.

The whole stack is managed with a single PowerShell command, `lb.ps1`, which supports zero-downtime rolling restarts.

---

## Table of contents

- [Architecture](#architecture)
- [Features](#features)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Running the stack (`lb.ps1`)](#running-the-stack-lbps1)
- [Running the frontend](#running-the-frontend)
- [Configuration](#configuration)
- [API reference](#api-reference)
- [How it works](#how-it-works)
- [Load balancer behaviour](#load-balancer-behaviour)
- [CI/CD](#cicd)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                         ┌──────────────────────────────┐
  Browser (Angular)      │   Nginx  :9090               │
  http://localhost:4200 ─►  rate limit 10 r/s/IP        │
                         │  round-robin + failover      │
                         └──┬────────┬────────┬────────┬┘
                            │        │        │        │
                        ┌───▼──┐ ┌───▼──┐ ┌───▼──┐ ┌───▼──┐
                        │ 8081 │ │ 8082 │ │ 8083 │ │ 8084 │   Spring Boot instances
                        └───┬──┘ └───┬──┘ └───┬──┘ └───┬──┘   (bound to 127.0.0.1)
                            └────────┴───┬────┴────────┘
                                ┌────────┴────────┐
                                │                 │
                          ┌─────▼─────┐     ┌─────▼─────┐
                          │  MySQL    │     │  Redis    │
                          │  :3306    │     │  :6379    │
                          │ (source   │     │ (cache,   │
                          │  of truth)│     │ optional) │
                          └───────────┘     └───────────┘
```

- The app instances are **stateless**, so any instance can serve any request.
- The instances only listen on `127.0.0.1`, so all traffic has to go through Nginx.
- Redis is **best-effort**: if it's down, requests fall through to MySQL and the app keeps working.

## Features

- **Short links**: base62-encoded from the database id (e.g. `/b7`, `/1F3`).
- **Custom aliases**: 3–30 characters of letters, digits, `-` or `_`. You get `409 Conflict` if the alias is taken.
- **Deduplication**: shortening the same URL twice from the same browser returns the existing link.
- **Click tracking**: a per-link click counter plus per-click events.
- **Analytics**: click totals for each of the last 7 days.
- **Per-browser ownership**: there's no login. Each browser generates a random id, sends it in an `X-Client-Id` header, and only ever sees and deletes its own links.
- **Redis caching**: redirects are cached for 30 minutes and evicted when a link is deleted.
- **Load balancing**: rate limiting, failover between instances, health checks, and zero-downtime rolling restarts.
- **Light and dark theme** in the UI.

## Tech stack

| Layer          | Technology                                              |
| -------------- | ------------------------------------------------------- |
| Backend        | Java 21, Spring Boot 4.1 (Web, Data JPA, Data Redis, Actuator) |
| Build          | Gradle (wrapper included)                               |
| Database       | MySQL 8                                                 |
| Cache          | Redis                                                   |
| Load balancer  | Nginx                                                   |
| Frontend       | Angular 19, TypeScript 5.7                              |
| Ops scripting  | PowerShell (Windows PowerShell 5.1+)                    |

## Project structure

```
.
├── frontend/                        Angular app
│   └── src/
│       ├── app/
│       │   ├── app.component.*      UI: shorten form, recent links, click chart
│       │   └── url-shortener.service.ts   API client (sends X-Client-Id)
│       └── environments/            apiBaseUrl per build (dev / prod)
│
└── loadbalancer/                    Spring Boot backend + ops
    ├── lb.ps1                       start / stop / restart / status / logs
    ├── nginx.conf                   load balancer config (port 9090)
    ├── .env.example                 template for local config & secrets
    ├── migration.sql                DB migration 001: click tracking
    ├── migration_002_owner_scoping.sql   DB migration 002: per-browser ownership
    └── src/main/java/com/example/loadbalancer/
        ├── controller/              REST endpoints
        ├── service/                 business logic, caching, base62
        ├── repository/              Spring Data JPA repositories
        ├── entity/                  JPA entities (UrlShortner, LinkClickEvent)
        ├── dto/                     response/cache records
        └── config/                  Redis serializer, CORS
```

## Prerequisites

| Tool     | Version  | Notes                                                                 |
| -------- | -------- | --------------------------------------------------------------------- |
| JDK      | 21       | `lb.ps1` expects `C:\Program Files\Java\jdk-21.0.10` by default. Override it with `LB_JAVA_HOME`. |
| MySQL    | 8.x      | Running on `localhost:3306`.                                          |
| Redis    | any      | Optional but recommended. Can run in WSL (`sudo apt install redis-server`). |
| Nginx    | 1.2x+    | Windows build, **or** installed inside WSL (see [Nginx on Windows vs WSL](#nginx-on-windows-vs-wsl)). |
| Node.js  | 18.19+ / 20+ | Only needed for the frontend.                                   |
| PowerShell | 5.1+   | Comes with Windows.                                                   |

## Setup

### 1. Clone

```bash
git clone <repo-url>
cd "Load Balancer"
```

### 2. Create the database

The app does **not** create tables itself (`ddl-auto=none`). Create the database and base table, then apply the migrations in order:

```sql
CREATE DATABASE IF NOT EXISTS appdb;
USE appdb;

-- Base table
CREATE TABLE IF NOT EXISTS url_shortner (
  id           BIGINT       NOT NULL AUTO_INCREMENT,
  original_url VARCHAR(255) DEFAULT NULL,
  short_url    VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (id)
);
```

> With this schema, original URLs are limited to 255 characters. For longer URLs, widen the column: `ALTER TABLE url_shortner MODIFY original_url VARCHAR(2048);`

```bash
mysql -u root -p appdb < loadbalancer/migration.sql                    # click tracking
mysql -u root -p appdb < loadbalancer/migration_002_owner_scoping.sql  # per-browser ownership
```

### 3. Configure

```powershell
cd loadbalancer
Copy-Item .env.example .env
notepad .env        # set DB_PASSWORD etc.
```

`.env` is gitignored, so never commit real credentials. See [Configuration](#configuration) for every setting.

### 4. Start everything

```powershell
.\lb.ps1 start
```

This builds the jar, starts the 4 instances, waits until each one reports healthy, and starts or reloads Nginx. When it finishes, open **http://localhost:9090/health**. It should return `{"status":"UP"}`.

## Running the stack (`lb.ps1`)

All commands are run from the `loadbalancer/` folder.

| Command                         | What it does                                                                  |
| ------------------------------- | ----------------------------------------------------------------------------- |
| `.\lb.ps1 start`                | Builds, starts any instance or Nginx that isn't running, and waits for health. Safe to run repeatedly. |
| `.\lb.ps1 stop`                 | Stops all instances gracefully (in-flight requests finish), then stops Nginx. |
| `.\lb.ps1 restart`              | Builds, then does a **rolling restart**, one instance at a time, with no downtime. |
| `.\lb.ps1 status`               | Shows the PID, health and uptime of each instance, plus Nginx and `/health` through the load balancer. |
| `.\lb.ps1 logs -Port 8083`      | Follows an instance's log.                                                    |

Useful flags:

- `-SkipBuild`: reuse the most recent release instead of rebuilding.
- `-Force` (with `stop`): stop Nginx even if Windows would block starting it again.

Details:

- **Detached processes.** Instances and Nginx are started outside the calling shell, so closing the terminal or VS Code doesn't kill them.
- **Releases.** Each build is copied to `releases/app-<timestamp>.jar` and the instances run from that copy. That way Gradle can rebuild while the instances are running (Windows locks jars that are in use). The last 3 releases are kept for rollback.
- **Logs.** Instance logs go to `run-logs/app-<port>.log`.
- **Exit codes.** Every command exits non-zero on failure, so `lb.ps1` can be used from Task Scheduler or CI.
- **Safe with other Nginx installs.** The script only ever touches processes started with *this project's* jar or `nginx.conf`, never other Nginx installs on the machine.

### Nginx on Windows vs WSL

Windows **Smart App Control** can block the unsigned `nginx.exe` download. `lb.ps1` handles this automatically:

- `LB_NGINX_MODE=auto` (the default) uses the Windows `nginx.exe` if Windows allows it to run, and otherwise uses Nginx inside WSL.
- `LB_NGINX_MODE=windows` or `LB_NGINX_MODE=wsl` forces one or the other.

One-time WSL setup:

```powershell
# 1. Install nginx in WSL and stop Ubuntu's own nginx service (it would take port 80)
wsl -u root -e sh -c "apt-get install -y nginx && systemctl disable --now nginx"

# 2. Share localhost between Windows and WSL
Set-Content "$env:USERPROFILE\.wslconfig" "[wsl2]`r`nnetworkingMode=mirrored" -Encoding ascii
wsl --shutdown

# 3. Start the stack; lb.ps1 picks the WSL nginx automatically
.\lb.ps1 start
```

WSL Nginx runs as your normal user, with its config, logs and temp files under `~/.lb-nginx/`. `lb.ps1` copies `nginx.conf` there on every `start` or `restart`.

## Running the frontend

```bash
cd frontend
npm install
npm start          # http://localhost:4200
```

The API URL is set in `src/environments/environment.ts` (dev) and `environment.prod.ts` (prod), and defaults to `http://localhost:9090`.

Production build:

```bash
npm run build      # output in frontend/dist/frontend/
```

If you serve the frontend from a different origin, add that origin to `APP_CORS_ALLOWED_ORIGINS`.

## Configuration

Each setting is read from an environment variable **or** from `loadbalancer/.env`. The defaults are for local development only.

### Application (Spring Boot)

| Variable                   | Default                              | Description                                       |
| -------------------------- | ------------------------------------ | ------------------------------------------------- |
| `DB_URL`                   | `jdbc:mysql://localhost:3306/appdb`  | JDBC URL                                          |
| `DB_USERNAME`              | `root`                               | Database user                                     |
| `DB_PASSWORD`              | `mysql`                              | Database password. **Set this in `.env`.**        |
| `DB_POOL_SIZE`             | `10`                                 | Max JDBC connections per instance                 |
| `REDIS_HOST`               | `localhost`                          | Redis host                                        |
| `REDIS_PORT`               | `6379`                               | Redis port                                        |
| `APP_BASE_URL`             | `http://localhost:9090/`             | Public URL that short links are built from (your domain in production) |
| `APP_CORS_ALLOWED_ORIGINS` | `http://localhost:4200`              | Comma-separated origins allowed to call the API   |

### Ops (`lb.ps1`)

| Variable             | Default                                   | Description                                  |
| -------------------- | ----------------------------------------- | -------------------------------------------- |
| `LB_JAVA_HOME`       | `C:\Program Files\Java\jdk-21.0.10`       | JDK used to run the instances                |
| `LB_NGINX_DIR`       | *(local path to the Windows nginx folder)* | Windows Nginx install directory             |
| `LB_NGINX_MODE`      | `auto`                                    | `auto`, `windows` or `wsl`                   |
| `LB_JAVA_OPTS`       | `-Xms256m -Xmx512m -XX:+ExitOnOutOfMemoryError` | JVM flags per instance                 |
| `LB_STARTUP_TIMEOUT` | `120`                                     | Seconds to wait for an instance to become healthy |

## API reference

All requests go through the load balancer at `http://localhost:9090`. Endpoints that are scoped to a browser read the `X-Client-Id` header.

| Method   | Path                    | Description                                    | Success            |
| -------- | ----------------------- | ---------------------------------------------- | ------------------ |
| `POST`   | `/shorten`              | Create a short link                            | `200` + link JSON  |
| `GET`    | `/{code}`               | Redirect to the original URL (counts a click)  | `302` + `Location` |
| `GET`    | `/api/links`            | Caller's 10 most recent links                  | `200` + array      |
| `DELETE` | `/api/links/{code}`     | Delete one of the caller's links               | `204`              |
| `GET`    | `/api/analytics/daily`  | Caller's clicks for each of the last 7 days    | `200` + array      |
| `GET`    | `/health`               | Load balancer health (proxied to an instance's `/actuator/health`) | `200` `{"status":"UP"}` |

### Create a short link

```bash
curl -X POST http://localhost:9090/shorten \
  -H "Content-Type: application/json" \
  -H "X-Client-Id: my-browser-id" \
  -d '{"originalUrl": "https://example.com/some/long/path", "alias": "launch"}'
```

```json
{
  "shortUrl": "http://localhost:9090/launch",
  "code": "launch",
  "originalUrl": "https://example.com/some/long/path",
  "clicks": 0,
  "createdAt": "2026-09-25T17:14:28.77287"
}
```

`alias` is optional. If you leave it out, you get a generated base62 code.

### Daily analytics

```json
[
  { "date": "2026-09-19", "clicks": 0 },
  { "date": "2026-09-20", "clicks": 4 },
  ...
  { "date": "2026-09-25", "clicks": 12 }
]
```

### Errors

Errors always come back as JSON in the form `{"message": "..."}`:

| Status | When                                                        |
| ------ | ----------------------------------------------------------- |
| `400`  | Invalid alias format                                        |
| `404`  | Unknown short code, or a link that isn't yours to delete    |
| `409`  | The alias is already taken                                  |
| `429`  | Rate limit exceeded (sent by Nginx)                         |
| `503`  | No healthy backend available (sent by Nginx)                |

## How it works

**Creating a link.** Without an alias, the row is inserted first and its auto-increment id is base62-encoded into the short code (`0-9a-zA-Z`), which keeps codes short and unique. With an alias, the alias is validated and checked for collisions. Either way, the new link is written to Redis.

**Redirecting.** `GET /{code}` checks Redis first (key `link:<code>`, 30-minute TTL). On a cache hit, the click counter is incremented in MySQL. If that update touches no rows, the link was deleted, so the cache entry is evicted and `404` is returned. On a miss, the link is loaded from MySQL and cached. Every redirect also records a `link_click_event` row for analytics.

**Cache resilience.** Every Redis call is wrapped in try/catch. A Redis outage only logs a warning, and requests are served from MySQL. Redis is also excluded from the health check, so a Redis outage never takes instances out of rotation.

**Ownership.** The frontend generates a UUID once per browser and stores it in `localStorage`. The backend stores it as `owner_id` and filters list, delete and analytics queries by it. This is scoping, **not authentication**: anyone who knows a client id can act as that browser.

## Load balancer behaviour

Configured in [`loadbalancer/nginx.conf`](loadbalancer/nginx.conf):

- **Round-robin** across `127.0.0.1:8081` to `8084`, with keep-alive connections to the upstreams.
- **Passive health checks** (`max_fails=2 fail_timeout=10s`): an instance that fails twice is skipped for 10 seconds.
- **Fast failover**: a 2 s connect timeout, and failed requests are retried on the next instance (up to 3 tries). POST and DELETE are only retried if they never reached a backend.
- **Rate limiting**: 10 requests/second per client IP, with a burst of 20. Excess requests get `429`.
- **`X-Upstream-Server` response header**: shows which instance served the request. Useful for watching the round-robin:

  ```powershell
  1..8 | % { (Invoke-WebRequest http://localhost:9090/api/links -UseBasicParsing).Headers["X-Upstream-Server"] }
  ```

- **Graceful rolling restarts**: `lb.ps1 restart` stops one instance at a time through Spring's graceful shutdown. Nginx routes around it while it's down. In testing, 976 requests sent during a full rolling restart all returned `200`.

## CI/CD

GitHub Actions workflows live in [`.github/workflows/`](.github/workflows/).

### CI: [`ci.yml`](.github/workflows/ci.yml)

Runs on every push and pull request to `main` or `master`. You can also run it by hand from the Actions tab. The four jobs run in parallel:

| Job | What it checks |
| --- | --- |
| **Backend** | Starts MySQL 8 and Redis 7 as service containers, applies the schema and both migrations, then runs `./gradlew build` (compile, tests, jar). Uploads the jar, and the test reports if anything fails. |
| **Frontend** | `npm ci`, the unit tests in headless Chrome, and a production build. Uploads `dist/`. |
| **Nginx** | `nginx -t` on `nginx.conf`, run in the official nginx image. |
| **Scripts** | Parses `lb.ps1` under Windows PowerShell 5.1. |

If you push again while a run is still going, the older run is cancelled.

### Release: [`release.yml`](.github/workflows/release.yml)

Pushing a version tag creates a GitHub Release with the build outputs attached:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release includes `loadbalancer-v1.0.0.jar`, `frontend-v1.0.0.tar.gz`, an `ops-v1.0.0.zip` (containing `lb.ps1`, `nginx.conf`, `.env.example` and the migrations), `SHA256SUMS.txt`, and auto-generated release notes.

### Dependabot: [`dependabot.yml`](.github/dependabot.yml)

Every week, Dependabot opens pull requests for outdated Gradle, npm and GitHub Actions dependencies, and CI tests each one. Angular packages are grouped into a single PR, since they have to be upgraded together.

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `502` / `503` from `:9090` | The instances are down. Run `.\lb.ps1 status`, then `.\lb.ps1 start`. |
| `/health` returns `404` | Nginx is running an old config. Run `.\lb.ps1 start` to reload it. |
| `An Application Control policy has blocked this file` | Smart App Control is blocking `nginx.exe`. Use WSL Nginx instead: see [Nginx on Windows vs WSL](#nginx-on-windows-vs-wsl). |
| `nginx (WSL) is not reachable on localhost:9090` | WSL networking isn't mirrored. Add `networkingMode=mirrored` under `[wsl2]` in `%USERPROFILE%\.wslconfig`, then run `wsl --shutdown`. |
| Instance fails during `start` | The script prints the last 25 log lines. The full log is in `run-logs/app-<port>.log`. The usual cause is MySQL not running or wrong credentials in `.env`. |
| `Port 90xx/808x is in use by something other than...` | Another program owns the port. Find it with `Get-NetTCPConnection -LocalPort 9090`. |
| Browser shows a CORS error | Add the frontend's origin to `APP_CORS_ALLOWED_ORIGINS` and run `.\lb.ps1 restart`. |
| Forgot your WSL password | From PowerShell: `wsl -u root passwd <your-linux-user>` |
