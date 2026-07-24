# 05a_exposure.R
# Exposure dose per GP x birth cohort: fraction of each reservation cycle
# overlapped by the cohort's exposure age window, summed over treated cycles.
# A child born in year b is age a during calendar year b + a; the window
# (a1, a2) spans calendar years [b + a1, b + a2], inclusive.

library(here)
library(dplyr)
library(tidyr)
library(purrr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

overlap_years <- function(win_start, win_end, cyc_start, cyc_end) {
    pmax(0, pmin(win_end, cyc_end - 1) - pmax(win_start, cyc_start) + 1)
}

for (state in c("raj", "up")) {
    if (!file.exists(here("data", "cohorts", sprintf("gp_cohort_%s.parquet", state)))) {
        message("Cohort cells not yet built, skipping: ", state)
        next
    }
    gp_cohort <- arrow::read_parquet(
        here("data", "cohorts", sprintf("gp_cohort_%s.parquet", state)))

    cycles <- CYCLES[[state]]

    exposure_grid <- expand_grid(
        birth_year = min(gp_cohort$birth_year):max(gp_cohort$birth_year),
        window = names(EXPOSURE_WINDOWS)
    ) |>
        mutate(
            a1 = map_dbl(window, ~ EXPOSURE_WINDOWS[[.x]][1]),
            a2 = map_dbl(window, ~ EXPOSURE_WINDOWS[[.x]][2])
        )
    for (cyc in names(cycles)) {
        cs <- cycles[[cyc]][1]
        ce <- cycles[[cyc]][2]
        exposure_grid[[paste0("frac_", cyc)]] <- overlap_years(
            exposure_grid$birth_year + exposure_grid$a1,
            exposure_grid$birth_year + exposure_grid$a2,
            cs, ce) / (ce - cs)
    }

    write_audit(exposure_grid, sprintf("05a_%s_exposure_grid.csv", state))

    grid_wide <- exposure_grid |>
        select(birth_year, window, starts_with("frac_")) |>
        pivot_wider(names_from = window,
                    values_from = starts_with("frac_"),
                    names_glue = "{.value}_{window}")

    gp_cohort <- gp_cohort |>
        left_join(grid_wide, by = "birth_year") |>
        mutate(
            dose_main = treat_2005 * frac_2005_main + treat_2010 * frac_2010_main +
                coalesce(treat_2015 * frac_2015_main, 0),
            dose_alt1 = treat_2005 * frac_2005_alt1 + treat_2010 * frac_2010_alt1 +
                coalesce(treat_2015 * frac_2015_alt1, 0),
            dose_alt2 = treat_2005 * frac_2005_alt2 + treat_2010 * frac_2010_alt2 +
                coalesce(treat_2015 * frac_2015_alt2, 0),
            any_exposure = as.integer(dose_main > 0),
            exp_2005 = treat_2005 * as.integer(frac_2005_main > 0),
            exp_2010 = treat_2010 * as.integer(frac_2010_main > 0),
            placebo_cohort = as.integer(birth_year <= PLACEBO_MAX_BIRTH_YEAR)
        )

    arrow::write_parquet(gp_cohort,
        here("data", "cohorts", sprintf("analysis_%s.parquet", state)))

    dose_summary <- gp_cohort |>
        group_by(birth_year) |>
        summarise(
            n_cells = n(),
            mean_dose = mean(dose_main, na.rm = TRUE),
            max_dose = max(dose_main, na.rm = TRUE),
            share_any_exposure = mean(any_exposure, na.rm = TRUE),
            .groups = "drop"
        )
    write_audit(dose_summary, sprintf("05a_%s_dose_by_cohort.csv", state))

    message(sprintf("%s: exposure attached; cohorts %d-%d, max dose %.2f",
                    state, min(gp_cohort$birth_year), max(gp_cohort$birth_year),
                    max(gp_cohort$dose_main, na.rm = TRUE)))
}

message("05a complete")
