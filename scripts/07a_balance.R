library(here)
library(dplyr)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "receiving_helpers.R"))
results <- list()
flow <- list()
source_coverage <- list()
for (state in c("raj", "up")) {
  panel <- treatment_panel(state)
  source_coverage[[state]] <- tibble(
    state = state, n_panel_rows = nrow(panel),
    n_rows_without_lgd = sum(is.na(panel$lgd_gp_code)),
    n_distinct_mapped_gps = n_distinct(panel$lgd_gp_code, na.rm = TRUE)
  )
  geography <- receiving_geography(state)
  ambiguous <- geography |>
    count(lgd_gp_code) |>
    filter(n > 1)
  geography <- anti_join(geography, ambiguous, by = "lgd_gp_code")
  source_gps <- panel |>
    filter(!is.na(lgd_gp_code)) |>
    select(lgd_gp_code, treat_2005, treat_2010, starts_with("pc01_")) |>
    distinct() |>
    anti_join(ambiguous, by = "lgd_gp_code")
  assert_unique(source_gps, "lgd_gp_code")
  source_gps <- left_join(source_gps, geography, by = "lgd_gp_code", relationship = "one-to-one")
  observed <- arrow::read_parquet(here("data", "cohorts", paste0("receiving_stages_", state, ".parquet")))
  coverage <- source_gps |>
    left_join(
      observed |> select(lgd_gp_code, n_men_all, n_missing_age, n_men_primary, n_linked_primary, n_gap_primary),
      by = "lgd_gp_code", relationship = "one-to-one"
    ) |>
    mutate(
      bridged = as.integer(lgd_gp_code %in% observed$lgd_gp_code),
      has_men = as.integer(!is.na(n_men_primary) & n_men_primary > 0),
      has_links = as.integer(!is.na(n_gap_primary) & n_gap_primary > 0),
      log_population = log1p(pc01_pca_tot_p),
      female_share = safe_ratio(pc01_pca_tot_f, pc01_pca_tot_p),
      literacy = safe_ratio(pc01_pca_p_lit, pc01_pca_tot_p),
      female_literacy = safe_ratio(pc01_pca_f_lit, pc01_pca_tot_f),
      linked_share = safe_ratio(n_linked_primary, n_men_primary),
      missing_age_share = safe_ratio(n_missing_age, n_men_all)
    )
  for (stage in c("source_mapped", "bridged", "male_sample", "gap_sample")) {
    d <- switch(stage,
      source_mapped = coverage,
      bridged = filter(coverage, bridged == 1),
      male_sample = filter(coverage, has_men == 1),
      gap_sample = filter(coverage, has_links == 1)
    )
    for (wave in c(2005, 2010)) {
      for (outcome in c(
        "log_population", "female_share", "literacy", "female_literacy",
        "bridged", "has_men", "has_links", "linked_share", "missing_age_share"
      )) {
        dd <- d |> mutate(birth_year = 0, age = 25)
        dd <- assignment_sample(dd, outcome, wave)
        if (n_distinct(dd$y) < 2) next
        m <- assignment_model(dd, wave)
        results[[paste(state, stage, wave, outcome)]] <- tibble(
          state = state, stage = stage, wave = wave, outcome = outcome,
          estimate = unname(coef(m)["treatment"]), se = unname(fixest::se(m)["treatment"]),
          p = unname(fixest::pvalue(m)["treatment"]), n_gps = nrow(dd),
          n_clusters = n_distinct(dd$block)
        )
      }
      flow[[paste(state, stage, wave)]] <- d |>
        group_by(treatment = .data[[paste0("treat_", wave)]]) |>
        summarise(
          n_gps = n(), n_men = sum(n_men_primary, na.rm = TRUE),
          n_linked = sum(n_linked_primary, na.rm = TRUE),
          n_unambiguous = sum(n_gap_primary, na.rm = TRUE), .groups = "drop"
        ) |>
        mutate(state = state, stage = stage, wave = wave)
    }
  }
}
write_audit(bind_rows(results), "receiving_balance_selection.csv")
write_audit(bind_rows(flow), "receiving_sample_flow.csv")

write_audit(bind_rows(source_coverage), "receiving_source_coverage.csv")
