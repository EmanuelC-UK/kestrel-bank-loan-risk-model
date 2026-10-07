# Kestrel Bank — Business Loan Risk Model

Can public Companies House records flag UK companies at risk of failure early?

Three signals (director resignations, overdue filings, outstanding charges) are combined into a 0–3 risk score and tested against known formal insolvencies across 9,844 UK companies.

## Key result

| Warning signs | Failing companies detected | Healthy companies wrongly flagged |
| :---- | :---- | :---- |
| 1 or more | 69.6% | 24.2% |
| 2 or more | 20.1% | 2.3% |
| 3 | 2.1% | 0.1% |

Each additional warning sign cuts false alarms, at the cost of catching fewer failures. Built on a balanced sample, so these show how well the score separates the two groups, not real-world default rates.

## Deliverables

- [Interactive dashboard (Tableau Public)](https://public.tableau.com/views/Project1_17902738396240/Dashboard1?:language=en-GB&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)
- [Executive brief](executive-brief.pdf)
- [Slide deck](slides.pdf)
- [Full documentation](documentation.pdf)
- [SQL queries](queries.sql)

## Tools

SQL (BigQuery) · Tableau · Companies House public data
