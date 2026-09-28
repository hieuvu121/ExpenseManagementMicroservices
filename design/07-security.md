# 7. Security

## Authentication happens once, at the edge

`api-gateway` verifies the JWT and passes the caller downstream as headers:

```java
.header("X-User-Id", userId)
.header("X-User-Email", email)
```

Downstream services never validate a token and never call auth-service to
resolve a caller. One HMAC verification per request, not one per service.

`JwtAuthenticationFilter` parses once — an earlier version called
`isTokenValid`, `extractUserId` and `extractEmail` separately, each parsing and
verifying the token again.

**Consequence:** a service reached directly, bypassing the gateway, is
unauthenticated. That is why only the gateway's port is published, and why each
service's `SecurityFilterChain` permits everything — the check already
happened.

## Authorization happens per service

The gateway answers "who are you". Each service answers "may you do this".

- expense-service: `HouseholdMembershipCache.requireMember`, `checkAdmin`
- household-service: role checks on the member row
- settlement-service: `SettlementAuthorizer`

### The bug this model made possible

settlement-service originally read `memberId` from the **URL path** and checked
it against itself:

```java
// memberId came from the path
if (!s.getFromMemberId().equals(memberId)) throw ...
```

`PUT /settlements/{id}/approve/{victimMemberId}` therefore let any authenticated
user mark someone else's debt paid. `grep -r "X-User-Id"` across the service
returned nothing — it was the only service not reading the caller from the
gateway.

Fixing it required a `userId → memberId` mapping the service did not have,
which is why `settlement_db` now keeps its own membership projection.

### The asymmetry that makes it work

| Check | Filters `removed_at`? | Why |
|---|---|---|
| `requireOwnMember` | **No** | A departed member keeps their debts and must still be able to pay them |
| `requireHouseholdMember` | **Yes** | The household-wide view is a membership privilege they do not keep |

Get that backwards and either a debt becomes uncollectable, or someone who left
can still read everyone's balances.

## Token revocation

Logout writes `blacklist:<token>` to Redis with a TTL matching the token's
remaining life, and publishes on `jwt-revoked` so every gateway evicts its
cached answer immediately. See [note 6](06-caching.md).

## Deliberately absent

**No refresh tokens.** The JWT lives ~10 hours and the clients handle expiry by
re-authenticating. Worth stating because it is easy to assume otherwise.

## Known weaknesses

- **All five schemas share one MySQL instance and one `root` user.** Nothing
  enforces the service boundary at the database — per-service users with grants
  scoped to their own schema would turn an accidental cross-schema read into a
  hard failure.
- Redis is unauthenticated on the compose network, and blacklist keys contain
  raw JWTs.
- `spring.jpa.hibernate.ddl-auto=update` in production — see
  [note 8](08-schema-management.md).
