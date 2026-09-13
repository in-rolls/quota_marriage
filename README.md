# Do Gender Quotas in Local Government Change When Girls Marry?

India reserves a random subset of Gram Panchayat (GP) head — *pradhan* — seats for women. If growing up under a woman pradhan raises girls' aspirations, it should show up in the two decisions that most define a young woman's life course: when she marries, and whom. This repository tests that at census scale, using parsed electoral rolls covering 173 million adults in Rajasthan and Uttar Pradesh, with GP-level reservation history as treatment.

**Author**: Gaurav Sood

## Key findings

**Exposure to a female-reserved pradhan does not credibly change marriage outcomes.** The point estimates are small, inconsistently signed, and — decisively — largely reproduced by cohorts who could not have been treated.

The core problem is the placebo. Women born on or before 1985 finished childhood before the first reservation cycle began, so their exposure dose is identically zero. Regressing their outcomes on the 2005 reservation assignment should return nothing. It does not:

| State | s2 (block × cohort FE) | s3 (GP FE, primary) | Placebo, dose ≡ 0 |
|---|---|---|---|
| Rajasthan | −0.086 (p = .021) | −0.053 (p = .135) | **−0.043 (p = .015)** |
| Uttar Pradesh | −0.101 (p = .001) | −0.076 (p = .008) | **−0.033 (p = .010)** |

Outcome is mean spousal age gap in years. The placebo coefficient is 51–81% of the Rajasthan estimate and 33–44% of the UP estimate, and is itself significant. Whatever produces the "treatment" effect also operates on women whose childhoods predate the treatment.

Three further reasons not to read these as causal:

- **The signs run backwards.** More exposure predicts *more* women married (Rajasthan `share_married_w`, s2: +0.0141, p = .005) and *fewer* women still in the natal home (`natal_share_w`, s2: −0.0139, p = .006). Both point toward earlier marriage, the opposite of the aspirations hypothesis.
- **The two states disagree.** UP's marriage-share and natal results collapse to zero once GP fixed effects absorb cross-village differences: `share_married_w` s3 = +0.0012 (p = .77), `natal_share_w` s3 = −0.0011 (p = .77). Only the spousal-gap estimate survives in UP, and that is the outcome with the worst placebo contamination.
- **The magnitudes are negligible.** A coefficient of −0.08 on a dose that runs 0 to 1 means roughly one month of spousal age gap at full exposure, against a sample median gap of about three years.

The early-marriage margin (`06f`) shows the same pattern in miniature. Rajasthan's estimates rise monotonically across observation-age bands — +0.0090 (ages 19–21), +0.0152 (22–25), +0.0354 (26–30) — which looks like a dose-response gradient until you run the zero-dose band. Women observed at 31–36 have no exposure, yet the 2005 assignment predicts their marriage share at +0.0071 (p = .0002). That bound covers the entire 19–21 estimate.

All estimates are in `data/audit/06a_couples_estimates.csv`, `06b_natal_estimates.csv`, `06d_placebo_estimates.csv`, and `06f_early_marriage_estimates.csv`; formatted tables are in `tabs/`.

## Research design

**Why two designs.** Rural North Indian marriage is patrilocal and village-exogamous: a married woman observed in GP *g* almost always grew up somewhere else. Her residence GP's reservation history is therefore not her own childhood exposure. Two designs work around this from opposite directions.

- **Couples design** — GP × wife-birth-cohort cells, capturing marriage-market and husband-side exposure. Outcomes: mean spousal age gap, share of couples with a gap of 5+ years, share of women married.
- **Natal-daughters design** — daughters leave the natal household roll when they marry, so "still listed under her father at observed age *a*" is itself a marriage-timing outcome, and it is measured in the GP where she actually grew up. `natal_ratio` (natal daughters ÷ natal sons) divides out roll-coverage differences between villages.

**Exposure.** Birth year is recovered as `roll_year − age`. Dose is the fraction of ages 5–15 spent under a female-reserved pradhan, summed across reservation cycles (Rajasthan and UP 2005–2010, 2010–2015, 2015–2020/2021; see `scripts/00_config.R`). Dose is mechanically zero for cohorts born on or before 1989 and rises for 1990–2000. Alternative windows of ages 6–16 and 10–16 are reported as sensitivity.

**Specifications.** All models are `fixest::feols`, weighted by cell size, clustered on GP (`scripts/06_estimation_helpers.R`):

| Spec | Fixed effects | Notes |
|---|---|---|
| s1 | district × cohort | Cross-GP, closest to the Beaman design; caste-stratum controls |
| s2 | (district, block) × cohort | Cross-GP within block; caste-stratum controls |
| s3 | GP + district × cohort | **Primary.** Within-GP; caste category absorbed |
| s4 | (district, block) × cohort | Cycle-specific dummies instead of a continuous dose |

Female reservation is randomized *within* caste-reservation strata, and caste-reserved GPs differ demographically, so every cross-GP specification conditions on the seat's caste category. Identification rests on that rotation being as-good-as-random with respect to marriage trends — which is exactly what the balance and placebo tests in [Caveats](#caveats) are meant to check, and largely what they fail.

## Data

Nothing large is committed. Numerical diagnostics in `data/audit/` and the source manifest are under version control: polling-station-level strings are fine to publish, elector names never are.

| Source | Contents | How to obtain |
|---|---|---|
| Harvard Dataverse [doi:10.7910/DVN/MUEGDT](https://doi.org/10.7910/DVN/MUEGDT) | Parsed electoral rolls, ~6.6 GB compressed: Rajasthan 2018 and UP 2017 | `Rscript scripts/01a_download_rolls.R` (optional `DATAVERSE_KEY`) |
| [`local_elections_rajasthan`](https://github.com/in-rolls/local_elections_rajasthan) and [`local_elections_up`](https://github.com/in-rolls/local_elections_up) | Shared election histories and election-to-LGD links | Fixed commits and SHA256 in `data/sources.json`; fetched by `01b` |
| [`in-rolls/quota_representation`](https://github.com/in-rolls/quota_representation) | Census 2001 covariates aggregated to LGD GPs | Pinned reference input; only Census columns are joined to the canonical election panels |
| [Rajasthan delimitation archive](https://doi.org/10.7910/DVN/SBF7DP) | Rajasthan delimitation: Devanagari village → GP | Original Dataverse file 7465072 and SHA256 pinned in `data/sources.json` |

Note the roll vintages: **Rajasthan 2018 and UP 2017**, not the 2014/2018 pairing listed in the upstream `electoral_rolls` documentation. The year columns in the data itself (`Draftroll_2018.aspx` for Rajasthan) are authoritative, and `scripts/00_config.R` sets `ROLL_YEAR` accordingly.

Scale at each stage:

| | Rajasthan | Uttar Pradesh |
|---|---|---|
| Elector rows | 43,265,056 | 129,336,463 |
| Roll parts | 48,182 | 148,537 |
| GPs observed in rolls | 3,468 | 20,357 |
| GP × cohort cells | 258,858 | 1,386,890 |
| Husband-linked couples | 12,616,335 (71.8%) | 23,801,316 (53.6%) |

Moving to the shared panels changes observed GP coverage from 3,471 to 3,468 in Rajasthan and from 21,096 to 20,357 in UP. The primary UP age-gap estimate changes from −0.077 to −0.076 years (p = .007 to .008). The UP natal-ratio estimate changes more, from −0.029 to −0.061 (p = .496 to .121); restricting both versions to their 19,964 common observed GPs gives −0.06232 and −0.06228, so that change is chiefly about sample coverage. Outcome construction and regression specifications are unchanged.

Husband linkage matches each married woman's stated relation name to a male elector in the same household within the same roll part: exact Devanagari match first, then Jaro-Winkler within 0.15 with a runner-up margin. No age-gap filter is applied, since the gap is the outcome.

## Relation to Beaman et al. (2012)

> Beaman, L., Duflo, E., Pande, R., & Topalova, P. (2012). Female Leadership Raises Aspirations and Educational Attainment for Girls: A Policy Experiment in India. *Science*, 335(6068), 582–586. [doi:10.1126/science.1212382](https://doi.org/10.1126/science.1212382)

Beaman et al. surveyed 495 villages in West Bengal and found that exposure to a female pradhan narrowed the gender gap in adolescent aspirations and educational attainment. Marriage timing is the natural administrative test of the same hypothesis: aspirations that survive into adulthood should delay marriage and narrow the spousal age gap.

Two things make that test worth running. First, a direct replication in [`in-rolls/beaman`](https://github.com/in-rolls/beaman) finds the original results fragile — the strongest effect (`no_housewife`) moves from p = .036 raw to p = .051 under wild-cluster bootstrap to p = .252 under Bonferroni, and no outcome survives multiple-testing correction. Second, that study's sample is 495 villages; this one observes 23,825 GPs and tens of millions of adults, so a real effect of plausible size should be easy to detect.

It is not detected here. But as the findings above make clear, this design's own diagnostics are weak enough that the null should be read as uninformative rather than as evidence of absence.

## Quick start

```bash
# 1. Clone
git clone https://github.com/in-rolls/quota_marriage.git
cd quota_marriage

# 2. Install R dependencies (R 4.6+; renv activates automatically)
R -e "renv::restore()"

# 3. Fetch the pinned shared election and reference inputs
Rscript scripts/01b_prepare_sources.R

# 4. Run the pipeline end to end (downloads ~6.6 GB of rolls at stage 01a)
Rscript scripts/99_run_all.R
```

Shared inputs use `INDIA_DATA_HOME` (default `~/data`), under `<provider>/<version>/<relative path>`. The resolver verifies SHA256 on every read and fetches missing files from the pinned commit or Dataverse file ID. Election histories and geographic links are produced upstream; exposure and outcome construction stay here. No local copies of the upstream panels are needed.

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `DATAVERSE_KEY` | unset | Dataverse API token; optional for public files |
| `INDIA_DATA_HOME` | `~/data` | Shared cache for pinned election and reference files |
| `DUCKDB_MEMORY_LIMIT` | `16GB` | DuckDB memory ceiling |
| `DUCKDB_THREADS` | `8` | DuckDB thread count |

**Expect this to take hours to days.** It pushes 173 million elector rows through DuckDB and scores tens of millions of candidate household pairs with string distances. Stage `04a` writes per-district parquet chunks behind a `.linkage_complete` sentinel and is resumable; downstream stages skip any state whose inputs are not yet built. `99_run_all.R` logs to `logs/pipeline_<timestamp>.log` and halts on the first error.

## Pipeline

Numbered stages in `scripts/`, run end to end by `scripts/99_run_all.R`. Heavy lifting is DuckDB and Arrow over hive-partitioned parquet; every matching stage emits an audit CSV to `data/audit/`.

| Stage | Purpose |
|---|---|
| 01a/01b | Download rolls; fetch SHA256-verified election and reference inputs |
| 02a/02b | Ingest csv.gz → parquet; typed and cleaned electors (uid, household key, names, relation, sex, age) |
| 03a–03e | Polling station → village → LGD GP bridge; treatment join; bridge-vs-treatment balance audit |
| 04a/04b | Husband linkage within household; natal-status flags; GP × birth-year × sex aggregates |
| 05a | Exposure dose per GP × cohort |
| 06a–06f | Couples design; natal design; random-rotation subsample; placebo cohorts; sensitivity; early-marriage margin |
| 07a | Covariate balance on the bridged sample |
| 08a/98 | NFHS-4 benchmarks; source integrity and treatment-panel checks |

The polling-station-to-village bridge is the hardest step: roll PDFs name polling stations in inconsistent Devanagari, and GP boundaries are re-delimited between roll vintages. Matching runs a cascade of Devanagari-exact, transliteration-exact, consonant-skeleton, and Jaro-Winkler fuzzy passes, blocked first on district and then on tehsil.

### Directory organization

```text
scripts/               # Numbered stages and shared helpers
data-raw/              # Small tracked inputs: NFHS-4 benchmarks, stopwords, district crosswalk
data/
├── sources.json       # Pinned election, geography and Census inputs
├── audit/             # Tracked numerical diagnostics
└── (everything else)  # Parquet, linkage chunks, aggregates — gitignored
tabs/                  # LaTeX regression tables + balance CSVs
figs/                  # Spec curve and validation plots
logs/                  # Pipeline run logs
```

## Outputs

| Path | Contents |
|---|---|
| `tabs/couples_main_{raj,up}.tex` | Couples design, all specs |
| `tabs/natal_main_{raj,up}.tex` | Natal-daughters design |
| `tabs/early_marriage_{raj,up}.tex` | Marriage share by observation-age band |
| `tabs/balance_{raj,up}.csv` | Unconditional covariate balance |
| `figs/sensitivity_spec_curve.pdf` | Spec curve over exposure window, bridge quality, natal definition, couples sample |
| `figs/validation/` | Marriage curves and sex ratios vs. NFHS-4, both states |
| `data/audit/*.csv` | Every intermediate diagnostic, including all estimate tables |

## Caveats

The diagnostics are the most informative part of this repository, and they mostly point the same way.

**Placebo cohorts fail.** As above: women born on or before 1985 have zero exposure, yet the 2005 reservation assignment predicts their spousal age gap at −0.043 (p = .015) in Rajasthan and −0.027 (p = .036) in UP. A stricter placebo variant leaves Rajasthan worse (−0.050, p = .008). Any treatment estimate smaller than roughly twice these values is indistinguishable from whatever the placebo is picking up.

**Covariate balance fails, badly in UP.** Conditioning on caste stratum and block, `treat_2005` predicts log population at −0.0352 (p = 9e-5), literacy at −0.0043 (p = .002), and female literacy at −0.0060 (p = 4e-5). `treat_2010` is imbalanced on all three as well. Rajasthan is milder but not clean: literacy −0.0064 (p = .013), female literacy −0.0062 (p = .029).

**Bridging is differential in UP.** Reserved GPs bridge to systematically fewer electors: `log_electors_bridged` on `treat_2005` is −0.0482 (p = 4.6e-7). Rajasthan shows no such pattern (p = .32 and p = .10). A treatment-correlated difference in who ends up in the analysis sample is a direct threat in UP.

**Face validity is weak, especially in UP.** UP's current-status marriage curve is non-monotone — 84.1% married at age 18 but 56.6% at 25 — which cannot be right and indicates that the relation field lags actual marriage at young ages, or that roll deletions trail household exits. Median spousal age gaps come in at 3.07 (Rajasthan) and 2.77 (UP) against NFHS/IHDS rural benchmarks of 4.8 and 4.5, and UP's share of negative gaps (8.1%) exceeds the plausible ceiling.

**The bridge relies on fuzzy matching.** Only 9.6% of Rajasthan polling stations match a village by exact Devanagari string against the vintage-matched delimitation. Another 22% match on exact transliteration, 41% on exact consonant skeleton, and the remaining 27% only by fuzzy string distance. UP is weaker still: 88% of its matches are skeleton-based and under 1% are exact transliteration. Match quality is a spec-curve dimension for this reason.

**Rotation is verifiable only in Rajasthan.** Testing consecutive reservation assignments for independence, all 32 Rajasthan districts pass; only 48 of 63 UP districts do. `06c` reruns the main models on the passing subsample.

**Marriage timing is measured indirectly.** Electoral rolls record current status, not event dates. "Married by age *X*" is identified only for the cohort actually observed at age *X*, which is why the early-marriage analysis is banded rather than pooled.

## Related repositories

- [`in-rolls/quota_representation`](https://github.com/in-rolls/quota_representation) — Reservation panels and the LGD crosswalk architecture; supplies treatment here
- [`in-rolls/delim_raj`](https://github.com/in-rolls/delim_raj) — Rajasthan delimitation, Devanagari village-to-GP mappings
- [`in-rolls/beaman`](https://github.com/in-rolls/beaman) — Replication of Beaman et al. (2012) with multiple-testing corrections
- [`in-rolls/electoral_rolls`](https://github.com/in-rolls/electoral_rolls) — The parsed electoral roll data this analysis consumes

## License

MIT. See [LICENSE](LICENSE).
