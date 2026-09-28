#!/usr/bin/env bash
# Measures the concurrent approve-versus-reverse race.
#
# ReversalDecisionService reads an expense's settlements, checks none is
# COMPLETED, and voids them. An approval committing between that read and that
# write is silently overwritten -- a debt somebody actually paid becomes VOIDED.
# @Transactional does not prevent it: under InnoDB REPEATABLE READ the SELECT is
# a consistent non-locking read while the UPDATE is a current read.
#
#   N=100 ./verify/race-approve-vs-reverse.sh with-version
#   N=100 ./verify/race-approve-vs-reverse.sh without-version   # @Version removed
#
# Timing: the reversal travels HTTP -> outbox poll -> Kafka -> decide(), which
# calibration puts at ~276-354ms after the POST. The approval is fired into that
# window with jitter, since the vulnerable span is decide()'s transaction.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh

LABEL="${1:-run}"
N="${N:-100}"
SPLITS="${SPLITS:-1}"         # settlements per expense; widens decide()'s window
AIM_MIN="${AIM_MIN:-240}"     # ms after the reversal POST
AIM_SPREAD="${AIM_SPREAD:-130}"
# A wide spread finds the crossover; a narrow one centred on it lands inside
# decide()'s transaction, which is the only place the race exists.
STAMP=$(date +%s)

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

echo "== race: $LABEL (N=$N, approve fired at ${AIM_MIN}-$((AIM_MIN+AIM_SPREAD))ms) =="

JWT_A=$(register_and_login "race_a_${LABEL}_$STAMP@example.com")
JWT_B=$(register_and_login "race_b_${LABEL}_$STAMP@example.com")
read -r HH MEM_A < <(create_household "$JWT_A" "Race $LABEL $STAMP")
MEM_B=$(join_household "$JWT_B" "$(household_code "$JWT_A")")
await_projections "$MEM_A" "$MEM_B" >/dev/null
echo "household=$HH  (A=$MEM_A debtor, B=$MEM_B creditor), $SPLITS settlement(s) per expense"

# Extra members go straight into expense-service's projection, the trick
# perf/seed.sh uses -- split validation only reads that table, and driving N
# real registrations would take minutes.
#
# Why bother: decide() voids every settlement for an expense in one
# transaction, so more settlements means a longer transaction and a wider race
# window. With a single settlement the window is a few milliseconds, narrower
# than the jitter of launching curl, and unreachable from outside.
EXTRA_IDS=""
if [ "$SPLITS" -gt 1 ]; then
  BASEID=$(( 900000 + RANDOM % 9000 ))
  vals=""
  for i in $(seq 1 $((SPLITS-2))); do
    mid=$((BASEID+i)); [ -n "$vals" ] && vals="$vals,"
    vals="$vals($mid,$HH,$mid,'Race $i','ROLE_MEMBER')"
  done
  docker exec mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"insert ignore into expense_db.household_member_summary (member_id,household_id,user_id,full_name,role) values $vals;\"" 2>/dev/null
  for i in $(seq 1 $((SPLITS-2))); do EXTRA_IDS="$EXTRA_IDS,{\"memberId\":$((BASEID+i)),\"amount\":1}"; done
fi

make_expense() {
  if [ "$SPLITS" -le 1 ]; then
    create_expense_as_member "$JWT_B" "$HH" 100 "$MEM_A" "$MEM_B"
  else
    curl -sf -X POST "$BASE/households/$HH/expenses" -H "Authorization: Bearer $JWT_B" \
      -H 'Content-Type: application/json' \
      -d "{\"amount\":$SPLITS,\"date\":\"$(date +%F)\",\"category\":\"Race\",\"currency\":\"VND\",\"method\":\"AMOUNT\",\"splits\":[{\"memberId\":$MEM_A,\"amount\":1}$EXTRA_IDS,{\"memberId\":$MEM_B,\"amount\":1}]}" \
      | jqv 'd["id"]'
  fi
}

CONFLICT_BEFORE=$(docker compose logs settlement-service 2>&1 | grep -ciE "OptimisticLock|StaleObjectState|Row was updated or deleted" || true)

paid_but_voided=0; reversed_but_owed=0
reversal_won=0; approval_won=0; inconclusive=0; raced=0

for i in $(seq 1 "$N"); do
  EXP=$(make_expense)
  [ -z "$EXP" ] && { inconclusive=$((inconclusive+1)); continue; }
  approve_expense "$JWT_A" "$HH" "$EXP" >/dev/null

  # Race against A's own settlement; the rest only serve to lengthen decide().
  SID=""
  for _ in $(seq 1 40); do
    cnt=$(sql "select count(*) from settlement_db.settlements where expense_id=$EXP;")
    [ "${cnt:-0}" -ge 1 ] && \
      SID=$(sql "select id from settlement_db.settlements where expense_id=$EXP and from_member_id=$MEM_A limit 1;")
    [ -n "$SID" ] && break; sleep 1
  done
  [ -z "$SID" ] && { inconclusive=$((inconclusive+1)); continue; }

  # A (the debtor) marks it paid so B (the creditor) is able to approve it.
  curl -s -o /dev/null -X PUT "$BASE/settlements/$SID/toggle/$MEM_A" -H "Authorization: Bearer $JWT_A"

  delay=$(( AIM_MIN + RANDOM % AIM_SPREAD ))
  curl -s -o /dev/null -X POST "$BASE/households/$HH/expenses/$EXP/reversal" -H "Authorization: Bearer $JWT_A" &
  python3 -c "import time;time.sleep($delay/1000)"
  curl -s -o /dev/null -X PUT "$BASE/settlements/$SID/approve/$MEM_B" -H "Authorization: Bearer $JWT_B"
  wait

  # Let the saga reach a terminal state.
  for _ in $(seq 1 25); do
    est=$(sql "select status from expense_db.expense where id=$EXP;")
    [ "$est" = "REVERSED" ] || [ "$est" = "APPROVED" ] && break
    sleep 1
  done
  sst=$(sql "select status from settlement_db.settlements where id=$SID;")
  paid=$(sql "select ifnull(paid_at,'') from settlement_db.settlements where id=$SID;")

  raced=$((raced+1))
  if [ "$sst" = "VOIDED" ] && [ -n "$paid" ]; then
    paid_but_voided=$((paid_but_voided+1))
  elif [ "$est" = "REVERSED" ] && [ "$sst" = "COMPLETED" ]; then
    reversed_but_owed=$((reversed_but_owed+1))
  elif [ "$est" = "REVERSED" ] && [ "$sst" = "VOIDED" ]; then
    reversal_won=$((reversal_won+1))
  elif [ "$est" = "APPROVED" ] && [ "$sst" = "COMPLETED" ]; then
    approval_won=$((approval_won+1))
  else
    inconclusive=$((inconclusive+1))
  fi
  [ $((i % 20)) -eq 0 ] && echo "  ...$i/$N"
done

CONFLICT_AFTER=$(docker compose logs settlement-service 2>&1 | grep -ciE "OptimisticLock|StaleObjectState|Row was updated or deleted" || true)
CONFLICTS=$(( CONFLICT_AFTER - CONFLICT_BEFORE ))
DIVERGED=$(divergent_count "$HH")

echo
echo "  ---- $LABEL ----"
echo "  races run                          : $raced"
echo "  optimistic-lock conflicts observed  : $CONFLICTS"
echo
echo "  VIOLATION paid debt voided          : $paid_but_voided"
echo "  VIOLATION expense reversed, debt owed: $reversed_but_owed"
echo
echo "  correct: reversal won (REVERSED/VOIDED)    : $reversal_won"
echo "  correct: approval won (APPROVED/COMPLETED) : $approval_won"
echo "  inconclusive                               : $inconclusive"
echo
echo "  divergent ledgers in this household : $DIVERGED"
echo "  -----------------"
