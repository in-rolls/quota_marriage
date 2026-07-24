# 06b_natal_design.R
# Design B: natal daughters. Daughters exit the natal roll at marriage, so
# presence under the father at the observed age is the marriage-timing
# outcome; natal_ratio benchmarks against brothers to net out roll coverage.

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

OUTCOMES_B <- c("natal_share_w", "natal_ratio")

all_tidy <- list()

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state)))

    models_by_outcome <- list()
    for (y in OUTCOMES_B) {
        models <- run_battery(cells, y, weight_var = "n_women")
        models_by_outcome[[y]] <- models
        all_tidy[[paste(state, y)]] <- battery_tidy(models, state, "natal", y)
    }

    aer_etable(
        list(models_by_outcome$natal_share_w$s1, models_by_outcome$natal_share_w$s2,
             models_by_outcome$natal_share_w$s3,
             models_by_outcome$natal_ratio$s2, models_by_outcome$natal_ratio$s3),
        file = here("tabs", sprintf("natal_main_%s.tex", state)),
        dict = c(DICT_MAIN, FE_DICT_BATTERY),
        headers = list("Natal share (women)" = 3, "Natal ratio (F/M)" = 2),
        notes = NOTES_NATAL
    )
}

tidy_all <- bind_rows(all_tidy)
write_audit(tidy_all, "06b_natal_estimates.csv")
message("06b complete")
