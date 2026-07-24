# 06d_placebo.R
# Placebo: cohorts born <= 1985 were >= 20 in 2005, past the exposure window
# by construction. Their outcomes regressed on the (future) 2005/2010 quotas
# should show nothing; a significant coefficient indicates a broken bridge or
# FE structure, not an effect.

library(here)
library(dplyr)
library(fixest)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

all_tidy <- list()

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state))) |>
        filter(placebo_cohort == 1)

    stopifnot(all(cells$dose_main == 0))

    castes <- paste(caste_controls(cells), collapse = " + ")
    castes <- if (nzchar(castes)) paste0(" + ", castes) else ""

    for (y in c("mean_gap", "share_gap_ge5", "natal_ratio")) {
        wvar <- if (y %in% c("mean_gap", "share_gap_ge5")) "n_couples" else "n_women"
        d <- cells |> filter(!is.na(.data[[y]]), .data[[wvar]] > 0)
        m2 <- feols(as.formula(sprintf(
                "%s ~ treat_2005 + treat_2010%s | fe_dist_block^birth_year", y, castes)),
            data = d, weights = as.formula(paste0("~", wvar)),
            cluster = ~lgd_gp_code)
        all_tidy[[paste(state, y)]] <- battery_tidy(
            list(placebo = m2), state, "placebo", y)

        # Strict placebo: cohorts born <= 1978 married almost entirely before
        # 2005, so even marriage-market effects of the 2005 cycle cannot
        # touch them
        d_strict <- d |> filter(birth_year <= 1978)
        m_strict <- feols(as.formula(sprintf(
                "%s ~ treat_2005 + treat_2010%s | fe_dist_block^birth_year", y, castes)),
            data = d_strict, weights = as.formula(paste0("~", wvar)),
            cluster = ~lgd_gp_code)
        all_tidy[[paste(state, y, "strict")]] <- battery_tidy(
            list(placebo_strict = m_strict), state, "placebo_strict", y)
    }
}

placebo_tbl <- bind_rows(all_tidy)
write_audit(placebo_tbl, "06d_placebo_estimates.csv")

sig <- placebo_tbl |> filter(p < 0.05)
if (nrow(sig) > 0) {
    warning("Placebo cohorts show significant treatment coefficients — investigate:\n",
            paste(sprintf("  %s %s %s: b=%.4f p=%.4f", sig$state, sig$outcome,
                          sig$term, sig$estimate, sig$p), collapse = "\n"))
} else {
    message("Placebo clean: no significant coefficients on future treatment")
}

message("06d complete")
