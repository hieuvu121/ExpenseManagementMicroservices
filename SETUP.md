# Setup Guide

## Prerequisites

Install the following before getting started:

- [Docker](https://www.docker.com/products/docker-desktop) & Docker Compose v2
- [Java 21](https://adoptium.net/) (only needed for local development without Docker)
- [Maven 3.9+](https://maven.apache.org/download.cgi) (only needed for local builds)
- [Node.js 20+](https://nodejs.org/) (only needed for frontend local development)

---

## Folder Setup

All services must live inside one parent folder alongside shared config files. Create the structure below before cloning.

### 1. Create the parent folder

```bash
mkdir ExpenseManagement-Microservices
cd ExpenseManagement-Microservices
```

### 2. Clone all service repositories

```bash
git clone https://github.com/hieuvu121/expenshie-eureka-server.git        eureka-server
git clone https://github.com/hieuvu121/expenshie-api-gateway.git          api-gateway
git clone https://github.com/hieuvu121/expenshie-auth-service.git         auth-service
git clone https://github.com/hieuvu121/expenshie-household-service.git    household-service
git clone https://github.com/hieuvu121/expenshie-expense-service.git      expense-service
git clone https://github.com/hieuvu121/expenshie-settlement-service.git   settlement-service
git clone https://github.com/hieuvu121/expenshie-notification-service.git notification-service
git clone https://github.com/hieuvu121/EmailService.git                    email-service
git clone https://github.com/hieuvu121/expenshie-ai-service.git           ai-service
git clone https://github.com/hieuvu121/expenshie-frontend.git             frontend
```

### 3. Add the shared configuration files

Place the following files in the root of `ExpenseManagement-Microservices/` (not inside any service folder):

- `docker-compose.yml` — orchestrates all services and infrastructure
- `init-db.sql` — creates the MySQL databases on first start
- `.env` — your environment variables (see [Configure environment variables](#configure-environment-variables) below)

Your folder should now look like this:

```
ExpenseManagement-Microservices/
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
├── docker-compose.yml
├── init-db.sql
└── .env
```

---

## Configure Environment Variables

Create a `.env` file in the project root with the following content, replacing placeholder values with your own:

```env
# Database
DB_USERNAME=root
DB_PASSWORD=your_db_password
MYSQL_ROOT_PASSWORD=your_db_password

# Mail (Gmail SMTP)
MAIL_HOST=smtp.gmail.com
MAIL_USERNAME=your_email@gmail.com
MAIL_PASSWORD=your_gmail_app_password
MAIL_FROM_EMAIL=your_email@gmail.com

# JWT
JWT_SECRET=your_super_secure_jwt_secret_key_at_least_32_chars

# OpenAI
OPENAI_API_KEY=sk-proj-your_openai_api_key

# CORS & URLs
APP_CORS_ALLOWED_ORIGINS=http://localhost:5173
APP_BASE_URL=http://localhost:8080
```

> **Gmail App Password:** Google Account → Security → 2-Step Verification → App Passwords. Generate one for "Mail" and paste it as `MAIL_PASSWORD`. Do not use your actual Gmail login password.

> **JWT Secret:** Any random string of 32+ characters.

> **OpenAI API Key:** Obtain from [platform.openai.com](https://platform.openai.com).

> **Never commit `.env` to version control.** It contains secrets.

---

## Quick Start — Docker Compose (Recommended)

Runs every service — MySQL, Kafka, Redis, and all microservices — in containers with a single command.

### Start all services

```bash
docker compose up --build
```

The first build takes several minutes while Maven downloads dependencies and Docker builds each image. Subsequent starts are much faster:

```bash
docker compose up
```

### Verify everything is running

| URL | What to expect |
|---|---|
| http://localhost:8761 | Eureka dashboard — all services listed as UP |
| http://localhost:8080 | API Gateway — returns 401 on unauthenticated requests |
| http://localhost:5173 | Frontend application login screen |

### Stop services

```bash
docker compose down
```

To also delete stored data (MySQL and Kafka volumes):

```bash
docker compose down -v
```

---

## Databases

MySQL initializes automatically on first start using `init-db.sql`. The following databases are created:

| Database | Service |
|---|---|
| `auth_db` | auth-service |
| `household_db` | household-service |
| `expense_db` | expense-service |
| `settlement_db` | settlement-service |
| `email_db` | email-service |

Each service manages its own schema via JPA/Hibernate on startup — no manual migrations needed.

---

## Local Development (Without Docker)

Run only the infrastructure in Docker and start individual services on the host JVM for faster iteration.

### 1. Start infrastructure only

```bash
docker compose up mysql kafka redis -d
```

Wait until MySQL is healthy before starting any service:

```bash
docker compose ps   # mysql should show "(healthy)"
```

### 2. Run a backend service

```bash
cd auth-service
mvn spring-boot:run
```

Pass environment variables inline if they are not already exported in your shell:

```bash
DB_HOST=localhost \
DB_NAME=auth_db \
DB_USERNAME=root \
DB_PASSWORD=your_password \
JWT_SECRET=your_secret \
EUREKA_SERVER_URL=http://localhost:8761/eureka \
KAFKA_BOOTSTRAP_SERVERS=localhost:9092 \
REDIS_HOST=localhost \
REDIS_PORT=6379 \
APP_BASE_URL=http://localhost:8080 \
mvn spring-boot:run
```

Adjust `DB_NAME` and variables per service. Refer to the table below for which variables each service needs.

**Startup order:**
1. `eureka-server` — must be running first
2. Everything else — in any order after Eureka is up

### 3. Run the frontend locally

```bash
cd frontend
npm install
npm run dev
```

The dev server starts at http://localhost:5173 and proxies API calls to http://localhost:8080.

---

## Environment Variable Reference

| Variable | Used by | Description |
|---|---|---|
| `DB_USERNAME` | All DB services | MySQL username |
| `DB_PASSWORD` | All DB services | MySQL password |
| `MYSQL_ROOT_PASSWORD` | MySQL container | Root password for MySQL init |
| `DB_HOST` | All DB services | MySQL hostname (`mysql` in Docker, `localhost` on host) |
| `DB_NAME` | All DB services | Per-service database name (e.g. `auth_db`) |
| `JWT_SECRET` | api-gateway, auth-service | Secret key for signing and verifying JWTs |
| `REDIS_HOST` | api-gateway, auth-service, expense-service | Redis hostname |
| `REDIS_PORT` | api-gateway, auth-service, expense-service | Redis port (default `6379`) |
| `KAFKA_BOOTSTRAP_SERVERS` | All async services | Kafka broker address |
| `EUREKA_SERVER_URL` | All services | Eureka registration URL |
| `OPENAI_API_KEY` | ai-service | OpenAI API key |
| `MAIL_HOST` | email-service | SMTP host (e.g. `smtp.gmail.com`) |
| `MAIL_USERNAME` | email-service | SMTP login email |
| `MAIL_PASSWORD` | email-service | SMTP app password |
| `MAIL_FROM_EMAIL` | email-service | Sender address shown in emails |
| `APP_CORS_ALLOWED_ORIGINS` | api-gateway | Allowed frontend origin(s) |
| `APP_BASE_URL` | auth-service | Base URL for email verification links |

---

## Troubleshooting

**Services not appearing in Eureka**
- Ensure `eureka-server` is fully started before other services.
- Inside Docker, `EUREKA_SERVER_URL` must be `http://eureka-server:8761/eureka`. On the host use `http://localhost:8761/eureka`.

**MySQL connection refused / services crash on startup**
- Wait for the MySQL health check to pass (`docker compose ps` shows `(healthy)`).
- Confirm `DB_PASSWORD` matches `MYSQL_ROOT_PASSWORD`.

**Kafka errors (producer/consumer timeout)**
- Inside Docker, `KAFKA_BOOTSTRAP_SERVERS` must be `kafka:9092`. On the host use `localhost:9092`.
- Kafka runs in KRaft mode — no ZooKeeper is required or expected.

**Emails not being delivered**
- Enable 2-Step Verification on the Gmail account first.
- Use an App Password, not the Google account login password.
- Confirm `MAIL_USERNAME` and `MAIL_FROM_EMAIL` match the Gmail account.

**Frontend API calls failing (network error / CORS)**
- Confirm the API Gateway is running on port 8080.
- Check that `APP_CORS_ALLOWED_ORIGINS` includes exactly `http://localhost:5173`.

**OpenAI requests failing**
- Verify `OPENAI_API_KEY` is valid and has available quota.
- The ai-service logs will show the specific OpenAI error response.

**Port conflicts**
- Default ports in use: `3306` (MySQL), `6379` (Redis), `9092` (Kafka), `8761` (Eureka), `8080` (Gateway), `5173` (Frontend).
- Stop any local processes using those ports before running Docker Compose.
