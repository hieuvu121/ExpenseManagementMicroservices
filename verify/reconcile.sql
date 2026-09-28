-- The oracle: does the expense ledger agree with the settlement ledger?
--
-- Settlements are derived from an expense at approval time -- one per split
-- whose member is not the expense's creator, for that split's amount
-- (SettlementService.createSettlementsForExpense). So for any APPROVED expense
-- the open settlement total must equal the sum of the non-creator splits.
--
-- This query deliberately reads across two schemas, which application code must
-- never do. As a diagnostic it is exactly the right shape: it is the only way
-- to see a divergence that, by construction, neither service can detect alone.
--
-- Every row returned is a ledger that disagrees with itself.

SELECT e.id                              AS expense_id,
       e.household_id,
       e.status,
       ROUND(COALESCE(sp.expected, 0), 2) AS expected_debt,
       ROUND(COALESCE(st.actual,   0), 2) AS actual_debt,
       ROUND(COALESCE(st.actual, 0) - COALESCE(sp.expected, 0), 2) AS drift
FROM expense_db.expense e

-- what the expense says is owed to its creator
LEFT JOIN (SELECT d.expense_id, SUM(d.amount) AS expected
           FROM expense_db.expense_split_details d
           JOIN expense_db.expense x ON x.id = d.expense_id
           WHERE d.member_id <> x.created_by_member_id
           GROUP BY d.expense_id) sp ON sp.expense_id = e.id

-- what settlement-service is actually tracking (VOIDED debts are not owed)
LEFT JOIN (SELECT s.expense_id, SUM(s.amount) AS actual
           FROM settlement_db.settlements s
           WHERE s.status <> 'VOIDED'
           GROUP BY s.expense_id) st ON st.expense_id = e.id

WHERE
      -- an approved expense whose debts do not match its splits
      (e.status = 'APPROVED'  AND COALESCE(sp.expected,0) <> COALESCE(st.actual,0))
      -- a reversed expense must owe nothing
   OR (e.status = 'REVERSED'  AND COALESCE(st.actual,0) <> 0)
      -- an unapproved expense must have produced no debt at all
   OR (e.status IN ('PENDING','REJECTED','REVERSING') AND COALESCE(st.actual,0) <> 0)
ORDER BY e.id;
