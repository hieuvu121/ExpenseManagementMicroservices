# Expense Management Microservices

A household expense platform on Spring Boot microservices. Households track
shared expenses, settle debts between members, get real-time notifications and
AI spending insights, through a React dashboard and an Expo mobile app.

Evolved from a monolith: https://github.com/hieuvu121/ExpenseManagementApp

> **[Design notes →](./design/)** — why the system is built this way: service
> boundaries, the transactional outbox, the expense-reversal saga, caching,
> security and the known gaps.

---

## Repositories

This is the umbrella repo. It tracks only what spans services — compose files,
`init-db.sql`, the observability stack and the load-test harness. Every service
is its own repository, cloned as a sibling directory.

| Service | Repository |
|---|---|
| `common` | https://github.com/hieuvu121/expenshie-common |
| `eureka-server` | https://github.com/hieuvu121/expenshie-eureka-server |
| `api-gateway` | https://github.com/hieuvu121/expenshie-api-gateway |
| `auth-service` | https://github.com/hieuvu121/expenshie-auth-service |
| `household-service` | https://github.com/hieuvu121/expenshie-household-service |
| `expense-service` | https://github.com/hieuvu121/expenshie-expense-service |
| `settlement-service` | https://github.com/hieuvu121/expenshie-settlement-service |
| `notification-service` | https://github.com/hieuvu121/expenshie-notification-service |
| `email-service` | https://github.com/hieuvu121/EmailService |
| `ai-service` | https://github.com/hieuvu121/expenshie-ai-service |
| `frontend` | https://github.com/hieuvu121/expenshie-frontend |

`common` is a shared jar of Kafka event contracts. It is built and installed
into the local Maven repository before any service that depends on it — the
Dockerfiles do this automatically.

---

## Features

**Households** — create, join by code, role-based access (admin / member).

**Expenses** — add, categorise and split across members. An admin's own expense
is approved on creation; a member's starts `PENDING` and needs admin approval.
An approved expense cannot be edited — it is **reversed** and re-posted, and
the reversal is refused if anyone has already settled against it.

**Settlements** — debts derived automatically from approved expenses. The payer
marks a debt paid, the creditor approves it.

**Notifications** — in-app over WebSocket (STOMP), plus transactional email for
activation and password reset.

**AI insights** — spending analysis via OpenAI, requested over Kafka
request/reply.

**Auth** — JWT issued by auth-service and verified once at the gateway. Logout
blacklists the token in Redis and pushes the revocation to every gateway
replica. *No refresh tokens — the JWT lasts ~10h and clients re-authenticate.*

---

## Architecture

```
Browser / Mobile
      │
      ▼
 API Gateway (:8080)          ← the only published port
      │                         JWT verified here, identity forwarded as X-User-Id
      │                         admission control: 500 in-flight, then 429
      │
      ├── auth-service         ← registration, login, JWT, logout
      ├── household-service    ← households, members, join codes
      ├── expense-service      ← expenses, splits, approval, reversal saga
      ├── settlement-service   ← debts, settlement, reversal veto
      ├── notification-service ← WebSocket push
      └── ai-service           ← OpenAI analysis
                                (email-service is Kafka-only: no HTTP, no Eureka)
      │
 Eureka Server (:8761)        ← used by the gateway's lb:// routes
                                and by Prometheus for scrape discovery

Infrastructure
  ├── MySQL 8      ← one instance, one schema per service
  ├── Kafka (KRaft) ← all inter-service communication
  └── Redis        ← JWT blacklist, response cache, invalidation pub/sub
```

**Requests are one hop deep.** The gateway routes to exactly one service, which
answers from its own schema. No service calls another over HTTP — where a
service needs foreign data it keeps a local projection fed by Kafka. See
[design note 1](./design/01-service-boundaries-and-data.md).

### Kafka topics

| Topic | Producer → Consumer | Carries |
|---|---|---|
| `user-events` | auth → household | `USER_REGISTERED` → `user_summary` projection |
| `email-events` | auth → email | Activation and password-reset mail |
| `household-member-events` | household → expense, settlement | `MEMBER_JOINED` / `MEMBER_LEFT` → membership projections |
| `expense-events` | expense → settlement | `EXPENSE_APPROVED` → settlements created |
| `websocket-events` | expense, settlement → notification | Client push |
| `ai-request-events` / `ai-response-events` | expense ↔ ai | Request/reply, correlated by header |
| `expense-reversal-requests` / `-replies` | expense ↔ settlement | The reversal saga |

### Databases

| Schema | Owner | Tables |
|---|---|---|
| `auth_db` | auth-service | `tbl_users`, `tbl_forgot_password`, `outbox_event` |
| `household_db` | household-service | `household`, `household_member`, `user_summary` |
| `expense_db` | expense-service | `expense`, `expense_split_details`, `household_member_summary`, `expense_reversal`, `outbox_event` |
| `settlement_db` | settlement-service | `settlements`, `household_member_summary`, `outbox_event` |
| `email_db` | email-service | `processed_event` |

---

## Services

| Service | Port | Stack |
|---|---|---|
| `eureka-server` | 8761 | Spring Boot, Netflix Eureka |
| `api-gateway` | 8080 | Spring Cloud Gateway (reactive), Redis |
| `auth-service` | dynamic | Spring Security, JWT, MySQL, Kafka, Redis |
| `household-service` | dynamic | Spring Data JPA, MySQL, Kafka |
| `expense-service` | dynamic | Spring Data JPA, MySQL, Kafka, Redis, Caffeine |
| `settlement-service` | dynamic | Spring Data JPA, MySQL, Kafka |
| `notification-service` | dynamic | WebSocket (STOMP), Kafka |
| `email-service` | dynamic | JavaMail, MySQL, Kafka |
| `ai-service` | dynamic | Spring AI, OpenAI, Kafka |
| `frontend` | 5173 | React 18, TypeScript, Vite, TailwindCSS |
| `mobile` | — | Expo / React Native |

Every service exposes `/actuator/prometheus` on management port **9090**, which
compose never publishes — actuator is reachable only from inside the network.

---

## Tech stack

**Backend** — Java 21, Spring Boot 3.4.5, Spring Cloud 2024.0.1 (Eureka,
Gateway), Spring Security, Spring Data JPA, Kafka in KRaft mode, Redis,
Caffeine, Spring AI + OpenAI.
*email-service is the exception: Java 17, Spring Boot 4.0.3, Spring Cloud 2025.1.0.*

**Frontend** — React 18, TypeScript, Vite 6, TailwindCSS 3, React Router 7,
STOMP over WebSocket, ApexCharts.

**Mobile** — Expo, React Native, TypeScript, jest.

**Infrastructure** — Docker Compose, MySQL 8, Kafka (KRaft, no ZooKeeper),
Redis, Prometheus, Grafana, cAdvisor and the kafka/mysqld/redis exporters.

---

## Layout

All repositories are cloned into the same parent folder. See
[SETUP.md](./SETUP.md) for step-by-step instructions.

```
ExpenseManagement-Microservices/
├── common/                  ← shared Kafka event contracts (built first)
├── eureka-server/
├── api-gateway/
├── auth-service/
├── household-service/
├── expense-service/
├── settlement-service/
├── notification-service/
├── email-service/
├── ai-service/
├── frontend/
├── mobile/                  ← Expo app
│
├── design/                  ← design notes (tracked here)
├── observability/           ← Prometheus config, Grafana dashboards, alert rules
├── perf/                    ← k6 load-test harness and seed script
│
├── docker-compose.yml       ← local stack
├── docker-compose.prod.yml  ← image-based, single EC2
├── init-db.sql              ← creates the five schemas
├── .env.example             ← copy to .env; never commit .env
└── SETUP.md
```

Only `design/`, `observability/`, `perf/`, the compose files, `init-db.sql` and
the docs live in this repo — the service directories are separate repositories
and are gitignored here.

---

## Getting started

See [SETUP.md](./SETUP.md). In short:

```bash
cp .env.example .env          # fill in DB, mail, JWT and OpenAI values
docker compose up -d --build
```

Load testing: [`perf/README.md`](./perf/README.md) — `./perf/seed.sh` then
`k6 run perf/load-test.js`.

> **Schema note.** Services run `spring.jpa.hibernate.ddl-auto=update`, which
> adds missing tables and columns but never alters an existing one. A fresh
> database is fine; an existing one may need manual `ALTER` statements after a
> column type or enum changes. See
> [design note 8](./design/08-schema-management.md).
