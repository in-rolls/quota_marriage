# quota_shaadi: Female Pradhan Reservation and Marriage Outcomes at Census Scale

Did girls exposed (ages ~5–15) to female-pradhan reservation cycles marry later
and with smaller spousal age gaps? Beaman et al. (2012, *Science*) report that
exposure to female leaders raised girls' aspirations in a 495-village sample;
a replication (`../beaman`) finds those effects do not survive wild-bootstrap
and multiple-testing corrections. This project runs the census-scale test:
reservation treatment at the Gram Panchayat (GP) level from
[`quota_raj`](../quota_raj), outcomes for tens of millions of adults observed in
parsed electoral rolls (Rajasthan 2014, Uttar Pradesh 2018).

## Two designs (patrilocal exogamy forces both)

Married women observed in GP *g* mostly grew up elsewhere, so residence-GP
treatment is not the bride's own exposure.

- **A. Couples design** (marriage-market / husband-side exposure): GP × wife-cohort
  cells; outcomes: mean spousal age gap, share gap ≥ 5, share married.
- **B. Natal-daughters design** (girls' own exposure): daughters exit the natal
  roll at marriage, so "still listed under father at observed age *a*" is the
  outcome; `natal_ratio` (natal daughters / natal sons) nets out roll coverage.

Exposure: `birth_year = roll_year − age`; dose = fraction of ages 5–15 spent
under a female-reserved pradhan (windows 6–16 and 10–16 as sensitivity).
Specs: `fixest`, GP and district × cohort fixed effects, cluster GP,
cell-N weights; random-rotation district subsample; placebo cohorts born ≤ 1985.

## Data dependencies (nothing large is committed)

| Source | What | How obtained |
|---|---|---|
| Harvard Dataverse doi:10.7910/DVN/MUEGDT | Parsed rolls: `rajasthan_all_clean+t13n.csv.gz` (2014), `up_all_clean+t13n.csv.gz.part*` (2018) | `scripts/01a_download_rolls.R` (optional `DATAVERSE_KEY` env var) |
| `../quota_raj` | Treatment panels keyed to LGD GP codes, LGD village→GP mappings, block-GP files | snapshotted by `scripts/01b_import_quota_raj.R` (`QUOTA_RAJ_DIR` env var overrides path) |
| `../delim_raj` | Rajasthan 2014 delimitation: Devanagari village→GP (vintage-matched to the 2014 rolls) | snapshotted by `01b` (`DELIM_RAJ_DIR`) |

## Pipeline

Numbered stages in `scripts/`, run end-to-end with `Rscript scripts/99_run_all.R`.
Heavy lifting is DuckDB/arrow over hive-partitioned parquet; matching stages all
emit audit CSVs to `data/audit/` (the only part of `data/` under version control;
polling-station-level strings are fine there, elector names never are).

| Stage | Purpose |
|---|---|
| 01a/01b | Download rolls; snapshot quota_raj/delim_raj inputs with md5+commit manifest |
| 02a/02b | Ingest csv.gz → parquet; typed/cleaned electors (uid, household key, names, relation, sex, age) |
| 03a–03e | Polling-station → village → LGD GP bridge; treatment join; bridge-vs-treatment balance audit |
| 04a–04c | Husband linkage within household; natal-status flags; GP × birth-year × sex aggregates |
| 05a | Exposure dose per GP × cohort |
| 06a–06e | Couples design; natal design; random-rotation subsample; placebo cohorts; sensitivity |
| 07a | Covariate balance on the bridged sample |
| 08a | Validation against NFHS-4 benchmarks (marriage curves, gap distribution, sex ratios) |
