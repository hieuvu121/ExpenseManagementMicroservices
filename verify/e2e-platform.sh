#!/usr/bin/env bash
# Everything the reversal suite does not touch: the outbox contract, email
# dedup, JWT revocation over Redis pub/sub, the settlement authorization
# matrix, and membership removal propagating to both projections.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh

STAMP=$(date +%s)
A="plat_a_$STAMP@example.com"; B="plat_b_$STAMP@example.com"
JWT_A=$(register_and_login "$A"); JWT_B=$(register_and_login "$B")
[ -n "$JWT_A" ] && [ -n "$JWT_B" ] || { echo "provisioning failed"; exit 1; }

echo "== outbox: registration wrote both events with distinct ids =="
check "two outbox rows for the registration" \
  "$(sql "select count(*) from auth_db.outbox_event where aggregate_id='$A';")" "2"
check "topics are user-events and email-events" \
  "$(sql "select group_concat(topic order by topic) from auth_db.outbox_event where aggregate_id='$A';")" \
  "email-events,user-events"
check "every event id is distinct" \
  "$(sql "select count(distinct event_id) from auth_db.outbox_event where aggregate_id='$A';")" "2"
# The bug this whole mechanism turned on: the id used to live on the row only.
check "the id is inside the payload, not only on the row" \
  "$(sql "select count(*) from auth_db.outbox_event where aggregate_id='$A' and payload like concat('%',event_id,'%');")" "2"
check "everything published" \
  "$(sql "select count(*) from auth_db.outbox_event where aggregate_id='$A' and published_at is null;")" "0"

echo
echo "== email-service: dedup table fed by the outbox =="
for _ in $(seq 1 30); do
  n=$(sql "select count(*) from email_db.processed_event;")
  [ "${n:-0}" -ge 1 ] && break; sleep 2
done
check "email-service recorded a processed event" "$([ "${n:-0}" -ge 1 ] && echo yes || echo no)" "yes"

echo
echo "== JWT revocation over Redis pub/sub =="
check "token works before logout" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/households/my" -H "Authorization: Bearer $JWT_A")" "200"
curl -s -o /dev/null -X POST "$BASE/auth/logout" -H "Authorization: Bearer $JWT_A"
check "blacklist key written to redis" \
  "$(docker exec redis redis-cli --scan --pattern 'blacklist:*' 2>/dev/null | wc -l | tr -d ' ' | awk '{print ($1>0)?"yes":"no"}')" "yes"
# The gateway caches the blacklist answer, so a pass here means the pub/sub push
# landed. Falling back to the TTL would take far longer than this window.
REVOKED="no"
for _ in $(seq 1 10); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/households/my" -H "Authorization: Bearer $JWT_A")" = "401" ] \
    && { REVOKED="yes"; break; }
  sleep 1
done
check "revoked token rejected within 10s (push, not TTL expiry)" "$REVOKED" "yes"
JWT_A=$(curl -sf -X POST "$BASE/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$A\",\"password\":\"$PASS\"}" | jqv 'd["token"]')

echo
echo "== settlement authorization matrix =="
read -r HH MEM_A < <(create_household "$JWT_A" "Platform House $STAMP")
MEM_B=$(join_household "$JWT_B" "$(household_code "$JWT_A")")
await_projections "$MEM_A" "$MEM_B" >/dev/null

EXP=$(create_expense_as_member "$JWT_B" "$HH" 80 "$MEM_A" "$MEM_B")
approve_expense "$JWT_A" "$HH" "$EXP" >/dev/null
for _ in $(seq 1 30); do
  SID=$(sql "select id from settlement_db.settlements where expense_id=$EXP limit 1;")
  [ -n "$SID" ] && break; sleep 1
done

check "own settlements readable" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/$MEM_A/$HH" -H "Authorization: Bearer $JWT_A")" "200"
check "another member's settlements forbidden" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/$MEM_B/$HH" -H "Authorization: Bearer $JWT_A")" "403"
check "cannot toggle as another member" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/settlements/$SID/toggle/$MEM_A" -H "Authorization: Bearer $JWT_B")" "403"
check "cannot approve as another member" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/settlements/$SID/approve/$MEM_B" -H "Authorization: Bearer $JWT_A")" "403"
check "household view allowed for a member" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/households/$HH" -H "Authorization: Bearer $JWT_A")" "200"
check "the fabricate-settlements endpoint is gone" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/settlements/households/$HH/expenses/999?createdByMemberId=$MEM_A" \
     -H "Authorization: Bearer $JWT_A" -H 'Content-Type: application/json' -d '[]')" "404"
check "no auth header is rejected" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/$MEM_A/$HH")" "401"

echo
echo "== membership removal propagates =="
curl -s -o /dev/null -X DELETE "$BASE/households/$HH/members/$MEM_B" -H "Authorization: Bearer $JWT_A"
for _ in $(seq 1 30); do
  r=$(sql "select count(*) from expense_db.household_member_summary where member_id=$MEM_B and removed_at is not null;")
  [ "${r:-0}" = "1" ] && break; sleep 1
done
check "expense-service tombstoned the member" "${r:-0}" "1"
check "settlement-service tombstoned the member" \
  "$(sql "select count(*) from settlement_db.household_member_summary where member_id=$MEM_B and removed_at is not null;")" "1"
DENIED="no"
for _ in $(seq 1 15); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/households/$HH/expenses?limit=5" -H "Authorization: Bearer $JWT_B")" != "200" ] \
    && { DENIED="yes"; break; }
  sleep 1
done
check "removed member loses expense reads (cache invalidated)" "$DENIED" "yes"
# The asymmetry that makes "debt survives removal" actually work.
check "removed member keeps access to their own debts" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/$MEM_B/$HH" -H "Authorization: Bearer $JWT_B")" "200"

summary
