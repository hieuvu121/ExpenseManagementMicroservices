#!/usr/bin/env bash
# Measures ledger divergence caused by editing approved expenses.
#
# Run it twice -- once with the updateExpense status guard removed, once with
# it in place -- and the difference is the whole of claim 1, as a number.
#
#   N=50 ./verify/divergence-ab.sh before
#   N=50 ./verify/divergence-ab.sh after
#
# Each run provisions its own household, so the two are independent and the
# oracle is scoped to that household only.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh

LABEL="${1:-run}"
N="${N:-50}"
STAMP=$(date +%s)

echo "== divergence measurement: $LABEL (N=$N) =="

JWT_A=$(register_and_login "div_a_${LABEL}_$STAMP@example.com")
JWT_B=$(register_and_login "div_b_${LABEL}_$STAMP@example.com")
read -r HH MEM_A < <(create_household "$JWT_A" "Divergence $LABEL $STAMP")
MEM_B=$(join_household "$JWT_B" "$(household_code "$JWT_A")")
await_projections "$MEM_A" "$MEM_B" >/dev/null
echo "household=$HH"

echo "  seeding $N expenses..."
IDS=()
for _ in $(seq 1 "$N"); do
  id=$(create_expense_as_member "$JWT_B" "$HH" 100 "$MEM_A" "$MEM_B")
  [ -n "$id" ] && IDS+=("$id")
done
echo "  created ${#IDS[@]}"

echo "  approving..."
for id in "${IDS[@]}"; do approve_expense "$JWT_A" "$HH" "$id" >/dev/null; done

# Settlements arrive over Kafka, so wait for them before measuring anything.
for _ in $(seq 1 60); do
  got=$(sql "select count(*) from settlement_db.settlements where household_id=$HH;")
  [ "${got:-0}" -ge "${#IDS[@]}" ] && break; sleep 1
done
echo "  settlements landed: ${got:-0}/${#IDS[@]}"

BASE_DRIFT=$(sql "select count(*) from (
  select e.id from expense_db.expense e
  left join (select d.expense_id, sum(d.amount) x from expense_db.expense_split_details d
             join expense_db.expense y on y.id=d.expense_id
             where d.member_id <> y.created_by_member_id group by d.expense_id) sp on sp.expense_id=e.id
  left join (select s.expense_id, sum(s.amount) a from settlement_db.settlements s
             where s.status<>'VOIDED' group by s.expense_id) st on st.expense_id=e.id
  where e.household_id=$HH and e.status='APPROVED'
    and coalesce(sp.x,0) <> coalesce(st.a,0)) t;")
echo "  drift before editing: ${BASE_DRIFT:-0}  (must be 0)"

echo "  attempting an amount edit on each approved expense..."
ACCEPTED=0
for id in "${IDS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$BASE/households/$HH/expenses/$id/update" \
    -H "Authorization: Bearer $JWT_A" -H 'Content-Type: application/json' \
    -d "{\"amount\":300,\"date\":\"$(date +%F)\",\"category\":\"Verify\",\"currency\":\"VND\",\"method\":\"AMOUNT\",\"splits\":[{\"memberId\":$MEM_A,\"amount\":150},{\"memberId\":$MEM_B,\"amount\":150}]}")
  [ "$code" = "200" ] && ACCEPTED=$((ACCEPTED+1))
done

DIVERGED=$(sql "select count(*) from (
  select e.id from expense_db.expense e
  left join (select d.expense_id, sum(d.amount) x from expense_db.expense_split_details d
             join expense_db.expense y on y.id=d.expense_id
             where d.member_id <> y.created_by_member_id group by d.expense_id) sp on sp.expense_id=e.id
  left join (select s.expense_id, sum(s.amount) a from settlement_db.settlements s
             where s.status<>'VOIDED' group by s.expense_id) st on st.expense_id=e.id
  where e.household_id=$HH and e.status='APPROVED'
    and coalesce(sp.x,0) <> coalesce(st.a,0)) t;")

DRIFT_VALUE=$(sql "select ifnull(round(sum(abs(coalesce(sp.x,0)-coalesce(st.a,0))),2),0) from expense_db.expense e
  left join (select d.expense_id, sum(d.amount) x from expense_db.expense_split_details d
             join expense_db.expense y on y.id=d.expense_id
             where d.member_id <> y.created_by_member_id group by d.expense_id) sp on sp.expense_id=e.id
  left join (select s.expense_id, sum(s.amount) a from settlement_db.settlements s
             where s.status<>'VOIDED' group by s.expense_id) st on st.expense_id=e.id
  where e.household_id=$HH and e.status='APPROVED'
    and coalesce(sp.x,0) <> coalesce(st.a,0);")

echo
echo "  ---- $LABEL ----"
echo "  expenses seeded and approved : ${#IDS[@]}"
echo "  edits accepted (HTTP 200)    : $ACCEPTED"
echo "  divergent ledgers            : ${DIVERGED:-0}"
echo "  total drift (currency)       : ${DRIFT_VALUE:-0}"
echo "  -----------------"
