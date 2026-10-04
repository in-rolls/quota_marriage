library(here)
library(dplyr)
library(ggplot2)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "receiving_helpers.R"))

est <- readr::read_csv(here("data", "audit", "receiving_estimates.csv"), show_col_types = FALSE)
raw <- readr::read_csv(here("data", "audit", "receiving_raw_means.csv"), show_col_types = FALSE)
balance <- readr::read_csv(here("data", "audit", "receiving_balance_selection.csv"), show_col_types = FALSE)
primary <- est |> filter(variant == "primary")
stopifnot(nrow(primary) == 8, all(is.finite(primary$boot_p)))
state_label <- function(x) ifelse(x == "raj", "Rajasthan", "Uttar Pradesh")
fmt <- function(x, digits = 3) formatC(x, format = "f", digits = digits)
profiles <- list()
counts <- list()
parental_profiles <- list()
for (state in c("raj", "up")) {
  cells <- arrow::read_parquet(here("data", "cohorts", paste0("receiving_", state, ".parquet")))
  parents <- arrow::read_parquet(here("data", "cohorts", paste0("parental_", state, ".parquet")))
  stopifnot(
    nrow(cells) > 0, !anyDuplicated(cells[c("lgd_gp_code", "birth_year")]),
    all(cells$n_linked <= cells$n_men), all(cells$n_gap <= cells$n_linked),
    all(is.na(cells$mean_gap[cells$n_gap == 0]))
  )
  profiles[[state]] <- cells |>
    group_by(age) |>
    summarise(
      n_men = sum(n_men), n_linked = sum(n_linked), n_gap = sum(n_gap),
      n_contested = sum(n_contested),
      linked_wife_share = sum(n_linked) / sum(n_men),
      mean_gap = sum(mean_gap * n_gap, na.rm = TRUE) / sum(n_gap),
      .groups = "drop"
    ) |>
    mutate(state = state)
  counts[[state]] <- cells |>
    filter(age <= 39) |>
    summarise(
      n_gps = n_distinct(lgd_gp_code), n_men = sum(n_men), n_linked = sum(n_linked),
      n_gap = sum(n_gap), n_contested = sum(n_contested),
      n_exact = sum(n_gap_exact)
    ) |>
    mutate(state = state)
  parental_profiles[[state]] <- parents |>
    group_by(age) |>
    summarise(
      n_parental_women = sum(n_parental_women), n_parental_men = sum(n_parental_men),
      ratio = safe_ratio(sum(n_parental_women), sum(n_parental_men)),
      .groups = "drop"
    ) |>
    mutate(state = state)
}
profile <- bind_rows(profiles)
count <- bind_rows(counts)
write_audit(profile, "receiving_age_profiles.csv")
write_audit(count, "receiving_primary_counts.csv")
write_audit(bind_rows(parental_profiles), "receiving_parental_profiles.csv")

p <- ggplot(profile, aes(age, 100 * linked_wife_share, color = state_label(state))) +
  geom_line(linewidth = .7) +
  labs(
    x = "Man's age in electoral roll", y = "Men with a linked wife (%)", color = NULL,
    caption = "Adult electoral records; an absent link does not identify an unmarried man."
  ) +
  theme_minimal(base_size = 11)
ggsave(here("figs", "receiving_linkage_by_age.pdf"), p, width = 7, height = 4)
p <- primary |>
  mutate(
    label = paste(state_label(state), wave),
    scale = ifelse(outcome == "mean_gap", 1, 100)
  ) |>
  ggplot(aes(estimate * scale, label)) +
  geom_vline(xintercept = 0, color = "grey60", linetype = 2) +
  geom_errorbar(aes(xmin = ci_low * scale, xmax = ci_high * scale), orientation = "y", width = .2) +
  geom_point() +
  facet_wrap(~outcome, scales = "free_x", labeller = as_labeller(c(
    linked_wife_share = "Linked-wife share (percentage points)",
    mean_gap = "Spousal age gap (years)"
  ))) +
  labs(
    x = "Adjusted assignment difference", y = NULL,
    caption = "95% cluster-t intervals; geographic × caste strata and birth-cohort fixed effects."
  ) +
  theme_minimal(base_size = 11)
ggsave(here("figs", "receiving_assignment_estimates.pdf"), p, width = 9, height = 4)

lines <- c(
  "# Do Gender Quotas in Local Government Change When Girls Marry?", "",
  "Electoral-roll evidence on reservation assignment and spouse matching in receiving villages in Rajasthan and Uttar Pradesh.", "",
  "**Author:** Gaurav Sood", "",
  "## Question and interpretation", "",
  "Under patrilocal marriage, a married woman's current village usually describes the receiving family rather than her childhood environment. This analysis therefore asks whether reservation assignment changes observed spouse matching among men in receiving villages. Possible channels include groom-family preferences, opportunities and village attractiveness; the data do not distinguish these mechanisms.", "",
  "Bride age at marriage remains an important question, but these inputs contain only one snapshot per state: Rajasthan 2018 and UP 2017. The source fields contain neither marriage dates or durations nor dated amendments. Current spouse ages identify an age gap, not when the marriage occurred. Ration data and longitudinal linkage are reserved for a later stage.", "",
  "## Main comparisons", "",
  "The primary population is male electoral records aged 19–39 in geographically linked GPs with unambiguous election mappings. Each GP receives equal total weight across its eligible birth-cohort cells, separately for each outcome. The linked-wife outcome includes all such men; age gaps require an unambiguous spouse link and valid ages.", "",
  "| State | GPs | Male records | Men with a linked wife | Unambiguous links with ages |",
  "|---|---:|---:|---:|---:|"
)
for (i in seq_len(nrow(count))) {
  r <- count[i, ]
  lines <- c(lines, sprintf(
    "| %s | %s | %s | %s | %s |", state_label(r$state),
    format(r$n_gps, big.mark = ","), format(r$n_men, big.mark = ","),
    format(r$n_linked, big.mark = ","), format(r$n_gap, big.mark = ",")
  ))
}
lines <- c(
  lines, "", "The following table reports raw equal-GP means alongside adjusted assignment contrasts. Linked-wife levels are percentages and differences are percentage points; age gaps and their differences are years. Intervals use block/samiti-clustered standard errors. Holm adjustment uses the eight primary wild-bootstrap p-values.", "",
  "| State / assignment | Outcome | Open mean | Reserved mean | Adjusted difference [95% CI] | Wild p | Holm p |",
  "|---|---|---:|---:|---:|---:|---:|"
)
for (i in seq_len(nrow(primary))) {
  r <- primary[i, ]
  means <- raw |> filter(state == r$state, wave == r$wave, variant == "primary", outcome == r$outcome)
  scale <- if (r$outcome == "mean_gap") 1 else 100
  outcome <- if (r$outcome == "mean_gap") "Spousal gap (years)" else "Linked wife (%)"
  lines <- c(lines, sprintf(
    "| %s / %s | %s | %s | %s | %s [%s, %s] | %s | %s |",
    state_label(r$state), r$wave, outcome, fmt(means$mean[means$treatment == 0] * scale),
    fmt(means$mean[means$treatment == 1] * scale), fmt(r$estimate * scale),
    fmt(r$ci_low * scale), fmt(r$ci_high * scale), fmt(r$boot_p), fmt(r$holm_boot_p)
  ))
}
lines <- c(
  lines, "",
  sprintf(
    "In UP, the linked-wife assignment contrasts are %+.2f and %+.2f percentage points for 2005 and 2010 (Holm-adjusted wild-bootstrap p = %.3f and %.3f). Across the four primary age-gap comparisons, %d intervals include zero. These findings concern adult recorded and linked spouses, not a reconstructed marriage date.",
    100 * primary$estimate[primary$state == "up" & primary$wave == 2005 & primary$outcome == "linked_wife_share"],
    100 * primary$estimate[primary$state == "up" & primary$wave == 2010 & primary$outcome == "linked_wife_share"],
    primary$holm_boot_p[primary$state == "up" & primary$wave == 2005 & primary$outcome == "linked_wife_share"],
    primary$holm_boot_p[primary$state == "up" & primary$wave == 2010 & primary$outcome == "linked_wife_share"],
    sum(primary$ci_low[primary$outcome == "mean_gap"] <= 0 & primary$ci_high[primary$outcome == "mean_gap"] >= 0)
  ), "",
  "These are different outcome samples and comparisons. A change in linked-wife share can reflect registration, co-residence, spouse age or matchability. A change in the age gap describes the composition of observed couples and need not imply that either spouse married later. Selection into observed couples can itself respond to reservation assignment.", "",
  "The raw levels describe this restricted sample: linked-wife shares are not marriage prevalence, and the average gaps are not population-wide spousal gaps. Restricting men to ages 19–39 while observing only registered adult wives limits which couples and gaps can appear.", "",
  "[Complete estimates and sensitivities](data/audit/receiving_estimates.csv) include age bands, native-name-only links, an age-gap trimming sensitivity, population weights and GP-clustered inference. [Age profiles](data/audit/receiving_age_profiles.csv) report counts and linked-wife rates at each age. [Assignment support](data/audit/receiving_assignment_support.csv) reports treatment overlap within geographic × caste strata.", "",
  sprintf(
    "Weighting changes the comparison: weighting UP's 2010 cells by male-record counts gives a linked-wife difference of %+.2f percentage points (block-clustered p = %.3f). Sensitivity results are exploratory and are outside the eight-test primary Holm adjustment.",
    100 * est$estimate[est$state == "up" & est$wave == 2010 & est$variant == "population_weighted" & est$outcome == "linked_wife_share"],
    est$p[est$state == "up" & est$wave == 2010 & est$variant == "population_weighted" & est$outcome == "linked_wife_share"]
  ), "",
  "## What the outcomes measure", "",
  "- **Linked-wife share:** distinct men referenced by at least one accepted wife link, divided by all eligible male records. Unlinked men have unknown marital status. Wives below electoral age, absent from the rolls, living elsewhere or not recorded under a husband cannot contribute a link.",
  "- **Spousal age gap:** husband's current age minus wife's current age, among men linked to exactly one wife with valid ages. Negative gaps remain in the primary analysis. Wife's current age at a fixed husband age is another expression of the same gap, not independent evidence about age at marriage.",
  "- **Parental-reference retention:** women recorded under a father relative to comparable men, with a father-or-mother sensitivity. The numerator and denominator are reported separately. Neither a parental reference nor an absent husband reference establishes unmarried status or residence with a parent.", "",
  "Resident women's married share is not the fraction of an original cohort of local daughters who married: incoming wives and departing daughters change its denominator. For example, 50 remaining daughters and 50 incoming wives give a 50% daughter share; 100 incoming wives lower it to 33% without another daughter departing.", "",
  "## Record identity, linkage and geography", "",
  "The earlier elector identifier combined filename, polling part, serial number and voter ID. Missing serial numbers and IDs caused distinct records to share a key. The receiving-family pipeline identifies records by cleaned-source parquet file and physical row position, then rebuilds spouse links. It does not keep an arbitrary member of a collided group. These are source-record identifiers, not longitudinal person identifiers; duplicate enrollment across rolls remains a measurement concern.", "",
  "Source PDFs have not been independently checked against the parsed records in this redesign. Structural and name-agreement checks cannot establish the accuracy of the original extraction. Within a roll part and normalized household number, native-name equality receives distance zero; remaining candidates use Jaro distance on transliterated names. This preserves the original stringdist call's zero-prefix-weight setting. Accept the best candidate at distance ≤0.15 only when the runner-up margin is ≥0.05, or there is no second candidate. A man claimed by multiple accepted wife links counts once in linked-wife share and is excluded from primary gap estimates. Native-exact sensitivity checks actual native-name equality, not merely a zero transliteration distance.", "",
  "Eight UP GP codes have competing source election mappings and are excluded from primary construction. The original ranking preferred Seekhar over Seeti in each case; geographic identity remains unverified. [Excluded mappings](data/audit/receiving_up_ambiguous_geography.csv) and state-specific `receiving_*_join_checks.csv` document the construction.", "",
  "## Assignment, exposure and uncertainty", "",
  "The main models separately compare 2005 and 2010 reservation assignments, absorbing assignment-year district–samiti/block × caste strata and birth-cohort fixed effects. The 2010 comparison controls for 2005 assignment. The 2005 comparison does not control for later reservation or later caste strata. These contrasts may include downstream reservation pathways; they do not isolate the effect of one term.", "",
  "Primary inference clusters at assignment-year district–samiti/block, with finite-sample cluster-t intervals. The eight primary comparisons also use 9,999 null-imposed Rademacher wild-bootstrap draws with saved seeds and inverted confidence intervals; the full output retains both cluster and bootstrap intervals. For the bootstrap, weighted within-stratum demeaning and square-root weights recover the same assignment coefficient in a smaller regression with explicit cohort indicators; strata are nested within bootstrap clusters. GP-clustered inference is a sensitivity. Strata without both assignments remain visible in support tables. Fixed-effect singletons are retained, and weights sum to one per GP after outcome-specific complete-case restrictions.", "",
  "[Balance and selection diagnostics](data/audit/receiving_balance_selection.csv) distinguish the [source panel with a usable LGD mapping](data/audit/receiving_source_coverage.csv), the geographic bridge, the male sample and the linked-gap sample. Missing LGD mappings preclude a roll comparison; this diagnostic does not certify the entire original lottery. Census 2001 differences and later linkage differences address different stages of the design.", "",
  sprintf(
    "In the mapped UP source sample, 2005 assignment is associated with %+.3f log points in Census 2001 population and %+.2f percentage points in female literacy. These baseline differences precede assignment and leave conditional comparability an assumption; clustering and the bootstrap do not resolve it.",
    balance$estimate[balance$state == "up" & balance$wave == 2005 & balance$stage == "source_mapped" & balance$outcome == "log_population"],
    100 * balance$estimate[balance$state == "up" & balance$wave == 2005 & balance$stage == "source_mapped" & balance$outcome == "female_literacy"]
  ), "",
  "[Secondary childhood-exposure models](data/audit/receiving_childhood_estimates.csv) use the man's birth year and GP fixed effects. Dose is the sum of reserved cycle fractions overlapping his childhood window, measured in cycle-equivalents. Missing reservation status remains missing when its cycle overlaps the window. Current GP is not verified childhood residence. Older cohorts are descriptive comparisons, not guaranteed negative controls.", "",
  "## Reproduction", "",
  "```sh", "Rscript -e 'renv::restore()'", "Rscript scripts/99_run_all.R --from-cleaned", "```", "",
  "The `--from-cleaned` entry point requires the local cleaned elector parquet files, ingested roll parquet files and polling-part treatment bridges. It rebuilds receiving-family links, cohorts, exposure, estimates, diagnostics, figures and this README. Omit the flag to run acquisition and geography preparation first. No source-record data or names are committed.", "",
  "```sh", "make test", "make validate", "make lint", "```", "",
  "The source manifest pins shared election panels, LGD links and Census covariates. State-specific `receiving_*_input_manifest.csv` files hash every cleaned elector parquet file used to define source-record identifiers. The electoral input is Harvard Dataverse [10.7910/DVN/MUEGDT](https://doi.org/10.7910/DVN/MUEGDT). The historical wife-cohort analysis is available in Git history at `f4373cb`; its exposure interpretation and link identifiers are superseded here. This redesign follows inspection of those results and is not a prospective preregistration.", "",
  "## Related repositories", "",
  "- [quota_spending](https://github.com/in-rolls/quota_spending): reservation assignment and public-goods outcomes.",
  "- [quota_representation](https://github.com/in-rolls/quota_representation): assignment histories, rotation and electoral representation.",
  "- [local_elections_rajasthan](https://github.com/in-rolls/local_elections_rajasthan) and [local_elections_up](https://github.com/in-rolls/local_elections_up): canonical election histories and LGD links.",
  "- [quota_aspirations](https://github.com/in-rolls/quota_aspirations): replication of the adolescent-aspirations study; the receiving-family outcomes here test a different question.", "",
  "## License", "", "MIT. See [LICENSE](LICENSE)."
)
writeLines(lines, here("README.md"))
writeLines(capture.output(sessionInfo()), here("data", "audit", "receiving_session_info.txt"))
