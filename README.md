# Expense Management Microservices

A full-stack household expense management platform built on a Spring Boot microservices architecture. It lets households track shared expenses, calculate settlements, receive notifications, and get AI-powered spending insights — all through a responsive React dashboard.

---

## Repositories

| Service | Repository |
|---|---|
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

---

## Features

### Household Management
- Create households and invite members
- Role-based access within each household

### Expense Tracking
- Add, edit, and categorize shared expenses
- Split expenses across household members
- Visual charts and spending summaries

### Settlements
- Automatic debt calculation between members
- Mark debts as settled and track history

### Notifications
- Real-time in-app notifications over WebSocket
- Email notifications for account events (verification, password reset, invitations)

### AI Insights
- AI-powered analysis of spending patterns via OpenAI
- Contextual suggestions based on expense history

### Authentication & Security
- JWT-based authentication with refresh tokens
- Token blacklisting via Redis on logout
- Email verification on registration

---

## Architecture

The system is composed of 9 backend services behind a single API Gateway, with service discovery managed by Netflix Eureka.

```
Browser / Mobile
      │
      ▼
 API Gateway (:8080)          ← single entry point, JWT validation, CORS
      │
      ├── auth-service         ← registration, login, JWT, email verification
      ├── household-service    ← households, members, invitations
      ├── expense-service      ← expenses, categories, splits
      ├── settlement-service   ← debt calculation, settlement tracking
      ├── notification-service ← real-time WebSocket notifications
      ├── email-service        ← SMTP email delivery
      └── ai-service           ← OpenAI expense analysis
      │
 Eureka Server (:8761)        ← service registry & discovery

Infrastructure
  ├── MySQL 8       ← per-service databases (auth_db, household_db, expense_db, …)
  ├── Apache Kafka  ← async event bus between services (KRaft, no ZooKeeper)
  └── Redis         ← JWT blacklist, response caching
```

### Async Event Flow (Kafka)

| Producer | Consumer | Event |
|---|---|---|
| auth-service | email-service | Account verification, password reset |
| household-service | notification-service | Member joined/left, invitation sent |
| expense-service | settlement-service | Expense created / updated / deleted |
| expense-service | ai-service | Expense data for AI analysis |
| settlement-service | notification-service | Settlement completed |

---

## Services

| Service | Port | Stack |
|---|---|---|
| `eureka-server` | 8761 | Spring Boot, Netflix Eureka |
| `api-gateway` | 8080 | Spring Cloud Gateway, Redis |
| `auth-service` | dynamic | Spring Security, JWT, MySQL, Kafka |
| `household-service` | dynamic | Spring Data JPA, MySQL, Kafka |
| `expense-service` | dynamic | Spring Data JPA, MySQL, Kafka, Redis |
| `settlement-service` | dynamic | Spring Data JPA, MySQL, Kafka |
| `notification-service` | dynamic | WebSocket (STOMP), Kafka |
| `email-service` | dynamic | JavaMail, MySQL, Kafka |
| `ai-service` | dynamic | Spring AI, OpenAI, Kafka |
| `frontend` | 5173 | React 18, TypeScript, Vite, TailwindCSS |

---

## Tech Stack

### Backend
- **Java 21**
- **Spring Boot 3.4.5**
- **Spring Cloud 2024.0.1** — Eureka, Gateway, OpenFeign
- **Spring Security** — JWT authentication
- **Spring Data JPA** — MySQL persistence
- **Apache Kafka** (KRaft mode) — asynchronous messaging
- **Redis** — token blacklist and caching
- **Spring AI** + OpenAI — AI expense insights

### Frontend
- **React 18** + **TypeScript**
- **Vite 6** — build tooling
- **TailwindCSS 3** — styling
- **React Router 7** — client-side routing
- **STOMP / WebSocket** — real-time notifications
- **ApexCharts** — data visualization

### Infrastructure
- **Docker** + **Docker Compose** — containerized deployment
- **MySQL 8** — relational storage (one database per service)
- **Apache Kafka** (KRaft) — event streaming
- **Redis** — in-memory store

---

## Folder Structure

All repositories must be cloned into the same parent folder alongside the shared configuration files. See [SETUP.md](./SETUP.md) for step-by-step instructions.

```
ExpenseManagement-Microservices/
├── eureka-server/           ← https://github.com/hieuvu121/expenshie-eureka-server
├── api-gateway/             ← https://github.com/hieuvu121/expenshie-api-gateway
├── auth-service/            ← https://github.com/hieuvu121/expenshie-auth-service
├── household-service/       ← https://github.com/hieuvu121/expenshie-household-service
├── expense-service/         ← https://github.com/hieuvu121/expenshie-expense-service
├── settlement-service/      ← https://github.com/hieuvu121/expenshie-settlement-service
├── notification-service/    ← https://github.com/hieuvu121/expenshie-notification-service
├── email-service/           ← https://github.com/hieuvu121/EmailService
├── ai-service/              ← https://github.com/hieuvu121/expenshie-ai-service
├── frontend/                ← https://github.com/hieuvu121/expenshie-frontend
├── docker-compose.yml       ← full-stack orchestration
├── init-db.sql              ← MySQL database initialization
└── .env                     ← environment configuration (never commit this)
```

---

## Getting Started

See [SETUP.md](./SETUP.md) for step-by-step setup instructions covering Docker Compose, local development, and environment configuration.
