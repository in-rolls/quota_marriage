library(here)
library(dplyr)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "receiving_helpers.R"))
results <- list()
for (state in c("raj", "up")) {
  cells <- arrow::read_parquet(here("data", "cohorts", paste0("receiving_", state, ".parquet")))
  for (outcome in c("linked_wife_share", "mean_gap")) {
    for (dose in c("dose_main", "dose_alt1", "dose_alt2")) {
      d <- cells |>
        filter(
          age >= 19, age <= 39, is.finite(.data[[outcome]]),
          is.finite(.data[[dose]]), !is.na(block_2010)
        ) |>
        mutate(y = .data[[outcome]], exposure = .data[[dose]], block = block_2010) |>
        group_by(lgd_gp_code) |>
        mutate(w = 1 / n()) |>
        ungroup()
      m <- fixest::feols(y ~ exposure | lgd_gp_code + fe_district^birth_year,
        data = d, weights = ~w, vcov = ~block, fixef.rm = "none",
        ssc = fixest::ssc(
          K.adj = TRUE, K.fixef = "nonnested",
          G.adj = TRUE, G.df = "min", t.df = "min"
        )
      )
      ci <- as.numeric(unlist(confint(m, "exposure")))
      results[[paste(state, outcome, dose)]] <- tibble(
        state = state, outcome = outcome, dose = dose,
        estimate = unname(coef(m)["exposure"]), se = unname(fixest::se(m)["exposure"]),
        p = unname(fixest::pvalue(m)["exposure"]), ci_low = ci[1], ci_high = ci[2],
        n_cells = nrow(d), n_gps = n_distinct(d$lgd_gp_code), n_clusters = n_distinct(d$block),
        missing_dose_cells = sum(is.na(cells[[dose]]) & cells$age >= 19 & cells$age <= 39)
      )
    }
  }
}
write_audit(bind_rows(results), "receiving_childhood_estimates.csv")
