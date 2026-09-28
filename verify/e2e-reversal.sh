#!/usr/bin/env bash
# The expense reversal saga, end to end against a running stack.
#
# Covers the accepted path, the refused path (the compensation, which unit
# tests cannot reach because it needs a real COMPLETED settlement), and the
# four guards the saga depends on.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh

STAMP=$(date +%s)

echo "== provisioning =="
# Two users, not one: createSettlementsForExpense skips splits belonging to the
# expense creator, so a single-member household produces no debts at all and
# there is nothing for the saga to void or refuse.
JWT_A=$(register_and_login "rev_a_$STAMP@example.com")
JWT_B=$(register_and_login "rev_b_$STAMP@example.com")
[ -n "$JWT_A" ] && [ -n "$JWT_B" ] || { echo "could not provision users"; exit 1; }

read -r HH MEMBER_A < <(create_household "$JWT_A" "Reversal House $STAMP")
MEMBER_B=$(join_household "$JWT_B" "$(household_code "$JWT_A")")
echo "household=$HH memberA=$MEMBER_A memberB=$MEMBER_B"
await_projections "$MEMBER_A" "$MEMBER_B" \
  && ok "membership replicated to both projections" \
  || bad "membership projections did not converge"

wait_status() {  # $1 expenseId $2 expected $3 tries
  for _ in $(seq 1 "$3"); do
    [ "$(sql "select status from expense_db.expense where id=$1;")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
await_settlement() {  # $1 expenseId -> settlementId on stdout
  for _ in $(seq 1 30); do
    local s; s=$(sql "select id from settlement_db.settlements where expense_id=$1 limit 1;")
    [ -n "$s" ] && { echo "$s"; return 0; }
    sleep 1
  done
  return 1
}

echo
echo "== SCENARIO 1: reversal accepted =="
EXP1=$(create_expense_as_member "$JWT_B" "$HH" 100 "$MEMBER_A" "$MEMBER_B")
check "admin approves the member's expense" "$(approve_expense "$JWT_A" "$HH" "$EXP1")" "200"
SID1=$(await_settlement "$EXP1")
check "settlement created from EXPENSE_APPROVED" "$([ -n "$SID1" ] && echo 1 || echo 0)" "1"

REV=$(curl -s -w '\n%{http_code}' -X POST "$BASE/households/$HH/expenses/$EXP1/reversal" \
  -H "Authorization: Bearer $JWT_A")
check "reversal returns 202 Accepted" "$(echo "$REV" | tail -1)" "202"
BODY=$(echo "$REV" | head -1)
check "state is in flight, not done" "$(echo "$BODY" | jqv 'd["state"]')" "AWAITING_SETTLEMENT"
SAGA1=$(echo "$BODY" | jqv 'd["sagaId"]')

wait_status "$EXP1" "REVERSED" 30
check "expense reached REVERSED" "$(sql "select status from expense_db.expense where id=$EXP1;")" "REVERSED"
check "settlement VOIDED" "$(sql "select status from settlement_db.settlements where expense_id=$EXP1;")" "VOIDED"
check "voiding_saga_id matches the returned sagaId" \
  "$(sql "select voiding_saga_id from settlement_db.settlements where expense_id=$EXP1;")" "$SAGA1"
check "GET reversal status resolves (not the /{range}/{status} route)" \
  "$(curl -s "$BASE/households/$HH/expenses/$EXP1/reversal" -H "Authorization: Bearer $JWT_A" | jqv 'd["state"]')" "COMPLETED"
check "saga COMPLETED" "$(sql "select state from expense_db.expense_reversal where saga_id='$SAGA1';")" "COMPLETED"
check "outbox fully drained" "$(sql "select count(*) from expense_db.outbox_event where published_at is null;")" "0"

echo
echo "== SCENARIO 2: reversal refused, expense compensated =="
EXP2=$(create_expense_as_member "$JWT_B" "$HH" 200 "$MEMBER_A" "$MEMBER_B")
approve_expense "$JWT_A" "$HH" "$EXP2" >/dev/null
SID2=$(await_settlement "$EXP2")

# A owes B here (B created the expense), so A marks it paid and B approves.
curl -s -o /dev/null -X PUT "$BASE/settlements/$SID2/toggle/$MEMBER_A"  -H "Authorization: Bearer $JWT_A"
curl -s -o /dev/null -X PUT "$BASE/settlements/$SID2/approve/$MEMBER_B" -H "Authorization: Bearer $JWT_B"
check "settlement is COMPLETED" "$(sql "select status from settlement_db.settlements where id=$SID2;")" "COMPLETED"

SAGA2=$(curl -s -X POST "$BASE/households/$HH/expenses/$EXP2/reversal" -H "Authorization: Bearer $JWT_A" | jqv 'd["sagaId"]')
wait_status "$EXP2" "APPROVED" 30
check "expense compensated back to APPROVED" "$(sql "select status from expense_db.expense where id=$EXP2;")" "APPROVED"
check "saga CANCELLED" "$(sql "select state from expense_db.expense_reversal where saga_id='$SAGA2';")" "CANCELLED"
REASON=$(sql "select failure_reason from expense_db.expense_reversal where saga_id='$SAGA2';")
case "$REASON" in *"already been settled"*) ok "failure reason recorded ($REASON)";;
  *) bad "failure reason: got '$REASON'";; esac
check "the completed settlement is untouched" "$(sql "select status from settlement_db.settlements where id=$SID2;")" "COMPLETED"

echo
echo "== SCENARIO 3: guards =="
check "editing an APPROVED expense is refused" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$BASE/households/$HH/expenses/$EXP2/update" \
     -H "Authorization: Bearer $JWT_A" -H 'Content-Type: application/json' \
     -d "{\"amount\":999,\"date\":\"$(date +%F)\",\"category\":\"Verify\",\"currency\":\"VND\",\"method\":\"AMOUNT\",\"splits\":[{\"memberId\":$MEMBER_A,\"amount\":999}]}")" "400"

EXP3=$(create_expense_as_member "$JWT_B" "$HH" 50 "$MEMBER_A" "$MEMBER_B")
check "reversing a PENDING expense is refused" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/households/$HH/expenses/$EXP3/reversal" -H "Authorization: Bearer $JWT_A")" "400"
check "paying a VOIDED settlement is refused" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/settlements/$SID1/toggle/$MEMBER_A" -H "Authorization: Bearer $JWT_A")" "400"
check "reading another member's settlements is forbidden" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/settlements/$MEMBER_A/$HH" -H "Authorization: Bearer $JWT_B")" "403"

echo
echo "== ledger consistency after all of the above =="
# Scoped to this run's household. The global check is ./reconcile.sh, which
# would also see the ledgers divergence-ab.sh corrupts on purpose.
check "no ledger divergence in this household" "$(divergent_count "$HH")" "0" 

summary
