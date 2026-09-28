#!/usr/bin/env bash
# Shared helpers. Source this; do not run it.
#
# The registration dance is the awkward part: email-service cannot deliver mail
# locally, so the activation token is read straight out of auth_db. Every script
# here needs it, which is why it lives in one place.

BASE="${BASE_URL:-http://localhost:8080/app/v1}"
PASS="${TEST_PASSWORD:-Passw0rd!}"

PASS_COUNT=0
FAIL_COUNT=0

ok()    { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT+1)); }
bad()   { echo "  FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
check() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected '$3', got '$2'"; }
jqv()   { python3 -c "import sys,json;d=json.load(sys.stdin);print(${1})" 2>/dev/null; }

# Run SQL against the compose mysql container, or anywhere DB_EXEC points.
sql() {
  if [ -n "${DB_EXEC:-}" ]; then $DB_EXEC -N -e "$1"
  else docker exec mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \"$1\"" 2>/dev/null | tr -d '\r'
  fi
}

# $1 email -> JWT on stdout
register_and_login() {
  curl -sf -X POST "$BASE/auth/register" -H 'Content-Type: application/json' \
    -d "{\"fullName\":\"Verify $1\",\"email\":\"$1\",\"password\":\"$PASS\"}" >/dev/null
  local t; t=$(sql "select activation_token from auth_db.tbl_users where email='$1';")
  curl -sf "$BASE/activate?token=$t" >/dev/null
  curl -sf -X POST "$BASE/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$PASS\"}" | jqv 'd["token"]'
}

# $1 jwt, $2 name -> "householdId memberId"
create_household() {
  curl -sf -X POST "$BASE/households/create" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "{\"name\":\"$2\"}" \
    | jqv 'd["id"],d["memberId"]' | tr '\n' ' '
}

# $1 jwt -> join code of the caller's first household
household_code() {
  curl -sf "$BASE/households/my" -H "Authorization: Bearer $1" | jqv 'd[0]["code"]'
}

# $1 jwt, $2 code -> memberId
join_household() {
  curl -sf -X POST "$BASE/households/join" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "{\"code\":\"$2\"}" | jqv 'd["memberId"]'
}

# Membership is replicated over Kafka into expense-service (split validation)
# and settlement-service (authorization). Nothing that depends on either can
# run until both projections have caught up.
# $1..$n memberIds
await_projections() {
  local ids; ids=$(printf '%s,' "$@"); ids=${ids%,}
  local e s
  for _ in $(seq 1 40); do
    e=$(sql "select count(*) from expense_db.household_member_summary where member_id in ($ids);")
    s=$(sql "select count(*) from settlement_db.household_member_summary where member_id in ($ids);")
    [ "${e:-0}" = "$#" ] && [ "${s:-0}" = "$#" ] && return 0
    sleep 2
  done
  echo "  WARN  projections did not converge (expense=$e settlement=$s of $#)" >&2
  return 1
}

# An admin's own expense is born APPROVED and publishes only EXPENSE_CREATED,
# so it never reaches settlement-service and produces no debt. A member's
# expense starts PENDING, and the admin's approval is what publishes
# EXPENSE_APPROVED. Anything needing real settlements must create as a member.
# $1 member-jwt, $2 householdId, $3 amount, $4 memberA, $5 memberB -> expenseId
create_expense_as_member() {
  local half=$(( $3 / 2 ))
  curl -sf -X POST "$BASE/households/$2/expenses" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' \
    -d "{\"amount\":$3,\"date\":\"$(date +%F)\",\"category\":\"Verify\",\"currency\":\"VND\",\"method\":\"AMOUNT\",\"splits\":[{\"memberId\":$4,\"amount\":$half},{\"memberId\":$5,\"amount\":$half}]}" \
    | jqv 'd["id"]'
}

# $1 admin-jwt, $2 householdId, $3 expenseId -> http status
approve_expense() {
  curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    "$BASE/households/$2/expenses/$3/approve" -H "Authorization: Bearer $1"
}

# Divergent ledgers, optionally scoped to one household.
#
# The suites must scope: verify/reconcile.sh reads the whole database, and
# divergence-ab.sh deliberately leaves corrupted ledgers behind in its own
# household as the evidence for claim 1. A suite that counted those would fail
# for someone else's data.
# $1 householdId (optional)
divergent_count() {
  local scope=""
  [ -n "${1:-}" ] && scope="e.household_id = $1 AND"
  sql "select count(*) from (
    select e.id from expense_db.expense e
    left join (select d.expense_id, sum(d.amount) x from expense_db.expense_split_details d
               join expense_db.expense y on y.id=d.expense_id
               where d.member_id <> y.created_by_member_id group by d.expense_id) sp on sp.expense_id=e.id
    left join (select s.expense_id, sum(s.amount) a from settlement_db.settlements s
               where s.status<>'VOIDED' group by s.expense_id) st on st.expense_id=e.id
    where $scope (
         (e.status='APPROVED' and coalesce(sp.x,0)<>coalesce(st.a,0))
      or (e.status='REVERSED' and coalesce(st.a,0)<>0)
      or (e.status in ('PENDING','REJECTED','REVERSING') and coalesce(st.a,0)<>0))) t;"
}

summary() {
  echo
  echo "================  $PASS_COUNT passed, $FAIL_COUNT failed  ================"
  [ "$FAIL_COUNT" -eq 0 ]
}
