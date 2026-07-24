# 06a_couples_design.R
# Design A: couples residing in the GP. Interpretation: husband-side /
# marriage-market exposure (patrilocal exogamy), stated in all table notes.

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

OUTCOMES_A <- c("mean_gap", "share_gap_ge5", "share_married_w")

all_tidy <- list()

for (state in c("raj", "up")) {
    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state)))

    models_by_outcome <- list()
    for (y in OUTCOMES_A) {
        wvar <- if (y == "share_married_w") "n_women" else "n_couples"
        models <- run_battery(cells, y, weight_var = wvar)
        models_by_outcome[[y]] <- models
        all_tidy[[paste(state, y)]] <- battery_tidy(models, state, "couples", y)
    }

    aer_etable(
        list(models_by_outcome$mean_gap$s2, models_by_outcome$mean_gap$s3,
             models_by_outcome$share_gap_ge5$s2, models_by_outcome$share_gap_ge5$s3,
             models_by_outcome$share_married_w$s2, models_by_outcome$share_married_w$s3),
        file = here("tabs", sprintf("couples_main_%s.tex", state)),
        dict = c(DICT_MAIN, FE_DICT_BATTERY),
        headers = list("Mean gap" = 2, "Gap $\\geq$ 5" = 2, "Married" = 2),
        notes = NOTES_COUPLES
    )

    micro <- arrow::open_dataset(here("data", "couples", state)) |>
        select(filename, wife_birth_year, gap, husband_contested,
               gap_implausible) |>
        collect() |>
        inner_join(
            arrow::read_parquet(
                here("data", "bridge", sprintf("ps_treatment_%s.parquet", state))) |>
                select(filename, lgd_gp_code, treat_2005, treat_2010, treat_2015,
                       fe_district, fe_dist_block),
            by = "filename") |>
        rename(birth_year = wife_birth_year) |>
        inner_join(
            cells |> distinct(birth_year, frac_2005_main, frac_2010_main),
            by = "birth_year") |>
        mutate(
            dose_main = treat_2005 * frac_2005_main + treat_2010 * frac_2010_main,
            exp_2005 = treat_2005 * as.integer(frac_2005_main > 0),
            exp_2010 = treat_2010 * as.integer(frac_2010_main > 0)
        )

    m_micro <- feols(gap ~ dose_main | fe_dist_block^birth_year,
                     data = micro, cluster = ~lgd_gp_code)
    m_micro_clean <- feols(gap ~ dose_main | fe_dist_block^birth_year,
                           data = micro |> filter(!husband_contested, !gap_implausible),
                           cluster = ~lgd_gp_code)
    all_tidy[[paste(state, "gap_micro")]] <- bind_rows(
        battery_tidy(list(micro_all = m_micro), state, "couples_micro", "gap"),
        battery_tidy(list(micro_clean = m_micro_clean), state, "couples_micro", "gap")
    )
}

tidy_all <- bind_rows(all_tidy)
write_audit(tidy_all, "06a_couples_estimates.csv")
message("06a complete")
