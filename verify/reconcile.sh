#!/usr/bin/env bash
# Runs the ledger oracle. Exits non-zero if the two schemas disagree.
#
#   ./verify/reconcile.sh            # human readable
#   ./verify/reconcile.sh --count    # just the number of divergent ledgers
set -uo pipefail
cd "$(dirname "$0")/.."

# Two shapes on purpose: -i streams the .sql file in, -e takes a literal.
# Mixing them by passing extra args to one function is how this hung the first
# time -- `docker exec -i` with nothing on stdin waits forever.
sql_file() { docker exec -i mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $1" 2>/dev/null; }
sql_expr() { docker exec mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \"$1\"" 2>/dev/null | tr -d '\r'; }

rows=$(sql_file "-N" < verify/reconcile.sql | grep -c . || true)
rows=${rows:-0}

if [ "${1:-}" = "--count" ]; then
  echo "$rows"
  [ "$rows" -eq 0 ]
  exit $?
fi

echo "== ledger reconciliation =="
if [ "$rows" -eq 0 ]; then
  total=$(sql_expr "select count(*) from expense_db.expense;")
  echo "  OK  no divergence across ${total:-0} expense(s)"
  exit 0
fi

echo "  DRIFT  $rows expense(s) disagree with their settlements"
echo
sql_file "-t" < verify/reconcile.sql
echo
echo "  Each row is money the two services do not agree on."
exit 1
