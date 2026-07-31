#!/usr/bin/env bash
# Provisions a throwaway user + household + expenses, then writes perf/.env
# with the JWT and household id for load-test.js to pick up.
#
#   ./perf/seed.sh [expense_count]      # default 200
#
# Needs the docker-compose stack up (mysql + api-gateway reachable).
set -euo pipefail

BASE="${BASE_URL:-http://localhost:8080/app/v1}"
COUNT="${1:-200}"
PASS="Passw0rd!"
EMAIL="perf_$(date +%s)@example.com"
OUT="$(cd "$(dirname "$0")" && pwd)/.env"

echo "seeding $EMAIL against $BASE"

curl -sf -X POST "$BASE/auth/register" -H 'Content-Type: application/json' \
  -d "{\"fullName\":\"Perf User\",\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null

# email-service can't deliver mail locally, so read the activation token from the db
TOKEN=$(docker exec mysql sh -c \
  "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \
   \"select activation_token from auth_db.tbl_users where email='$EMAIL';\"" \
  2>/dev/null | tr -d '\r')
curl -sf "$BASE/activate?token=$TOKEN" >/dev/null

JWT=$(curl -sf -X POST "$BASE/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# household names are globally unique (HouseholdService.java:33) — reusing one
# 500s, so derive the name from the run's timestamp
read -r HH MEMBER < <(curl -sf -X POST "$BASE/households/create" \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Perf House ${EMAIL%%@*}\"}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["id"],d["memberId"])')

# household-service publishes the member over Kafka; expense-service validates
# splits against its own projection, so wait for that to land before inserting.
echo "waiting for member $MEMBER to replicate into expense-service"
for _ in $(seq 1 30); do
  probe=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/households/$HH/expenses" \
    -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
    -d "{\"amount\":1,\"date\":\"$(date +%F)\",\"category\":\"Probe\",\"currency\":\"VND\",\"method\":\"EQUAL\",\"splits\":[{\"memberId\":$MEMBER,\"amount\":1}]}")
  [ "$probe" = "200" ] && break
  sleep 1
done
[ "$probe" = "200" ] || { echo "member never replicated (last status $probe)"; exit 1; }

echo "seeding $COUNT expenses into household $HH"
fails=0
for i in $(seq 1 "$COUNT"); do
  # integer amount, single split — sum must equal the total exactly
  amt=$((RANDOM % 500 + 1))
  curl -sf -X POST "$BASE/households/$HH/expenses" \
    -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
    -d "{\"amount\":$amt,\"date\":\"$(date +%F)\",\"category\":\"Groceries\",\"description\":\"perf seed $i\",\"method\":\"EQUAL\",\"currency\":\"VND\",\"splits\":[{\"memberId\":$MEMBER,\"amount\":$amt}]}" \
    >/dev/null || fails=$((fails + 1))
done
[ "$fails" -gt 0 ] && echo "WARNING: $fails/$COUNT expense inserts failed"

# Spread the expenses across several creators.
#
# This is not cosmetic. Every expense above is created by the same member, and
# a page whose rows share one creator lets Hibernate's first-level cache turn
# the per-row creator lookup in ExpenseService.toDTO() into a single query. That
# made an N+1 invisible: on 2026-07-31 the same build measured p95 4.7ms with
# one creator and p95 178ms with nine. A benchmark that cannot see the bug is
# worse than no benchmark.
#
# Members are inserted straight into expense-service's projection table rather
# than driven through the household join API, which would need a registration,
# an activation-token lookup and an invite per member.
EXTRA_MEMBERS="${EXTRA_MEMBERS:-9}"
echo "spreading expenses across $EXTRA_MEMBERS creators"
values=""
for i in $(seq 1 "$EXTRA_MEMBERS"); do
  mid=$((900000 + i))
  [ -n "$values" ] && values="$values,"
  values="$values($mid,$HH,$mid,'Perf Member $i','ROLE_MEMBER')"
done
docker exec mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"
  insert ignore into expense_db.household_member_summary
    (member_id, household_id, user_id, full_name, role) values $values;
  update expense_db.expense
     set created_by_member_id = 900001 + (id % $EXTRA_MEMBERS)
   where household_id = $HH;\"" 2>/dev/null

cat > "$OUT" <<EOF
JWT=$JWT
HOUSEHOLD_ID=$HH
MEMBER_ID=$MEMBER
PERF_EMAIL=$EMAIL
EOF

echo "wrote $OUT (household=$HH, jwt valid ~10h)"
