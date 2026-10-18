-- The 30-day plan checklist (PLAN in the dashboard). Ids match the dashboard's
-- 'p1'..'p10' so ticks saved under 'hl-plan' map one to one.
insert into public.plan_items (id, group_name, title, note, sort_order) values
  ('p1',  'This week',  'Get three certified copies of the death certificate', 'Keep the originals somewhere safe. Insurers often ask for certified copies.', 1),
  ('p2',  'This week',  'Send the missing documents to the life insurer', 'Two items are outstanding. See Debts & insurance.', 2),
  ('p3',  'This week',  'Confirm the joint account covers the next bills', 'The Money view shows what is due and when.', 3),
  ('p4',  'This month', 'Ask the mortgage and car lenders how the claim affects each loan', 'Some loans are cleared or reduced by life cover. Only the lender can confirm.', 4),
  ('p5',  'This month', 'Check the beneficiary on the retirement fund', 'Beneficiary rules decide where the money goes. Read the exact wording.', 5),
  ('p6',  'This month', 'Start the ownership transfer for the investment account', 'The brokerage or a lawyer can explain the steps.', 6),
  ('p7',  'This month', 'Review subscriptions and pause the ones you do not use', 'Check notice periods first. The Money view has the list.', 7),
  ('p8',  'When ready', 'Meet a licensed financial advisor about the household plan', 'Bring this dashboard as a starting point.', 8),
  ('p9',  'When ready', 'Speak with a lawyer about estate and guardianship', 'Rules vary by country. A local professional is the right person to ask.', 9),
  ('p10', 'When ready', 'Review your own will and protection cover', 'Take this slowly. Review them when you are ready.', 10);

-- Fallback FX for USD-priced holdings in AED households. The dirham has been
-- pegged at 3.6725 per US dollar by the Central Bank of the UAE since 1997.
-- The market edge function replaces this with a live rate when it can.
insert into public.fx_rates (base, quote, rate, source) values ('USD', 'AED', 3.6725, 'CBUAE fixed peg')
on conflict do nothing;
