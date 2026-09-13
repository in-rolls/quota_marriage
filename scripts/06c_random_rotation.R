# 06c_random_rotation.R
# Restrict to districts where consecutive quota assignments are consistent
# with an independent lottery (chi-square p > 0.05, quota_raj 04c/05b logic)
# and re-run the primary specs of both designs.

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

all_tidy <- list()
rotation_audit <- list()

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    district_var <- if (state == "raj") "district_std_2010" else "district_name_eng_2010"

    panel <- treatment_panel(state)

    chisq <- compute_district_chisq(panel, "treat_2005", "treat_2010", district_var)
    random_districts <- chisq |>
        filter(chisq_p > 0.05) |>
        pull(!!sym(district_var))

    rotation_audit[[state]] <- chisq |>
        rename(district = !!sym(district_var)) |>
        mutate(state = state, random_rotation = chisq_p > 0.05)

    message(sprintf("%s: %d of %d districts consistent with random rotation",
                    state, length(random_districts), nrow(chisq)))

    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state))) |>
        filter(fe_district %in% random_districts)

    for (y in c("mean_gap", "share_married_w")) {
        wvar <- if (y == "mean_gap") "n_couples" else "n_women"
        models <- run_battery(cells, y, weight_var = wvar)
        all_tidy[[paste(state, y)]] <- battery_tidy(
            models[c("s2", "s3")], state, "couples_random_rotation", y)
    }
    for (y in c("natal_share_w", "natal_ratio")) {
        models <- run_battery(cells, y, weight_var = "n_women")
        all_tidy[[paste(state, y)]] <- battery_tidy(
            models[c("s2", "s3")], state, "natal_random_rotation", y)
    }
}

write_audit(bind_rows(rotation_audit), "06c_rotation_districts.csv")
write_audit(bind_rows(all_tidy), "06c_random_rotation_estimates.csv")
message("06c complete")
