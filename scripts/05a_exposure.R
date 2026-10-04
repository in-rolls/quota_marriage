library(here)
library(dplyr)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "receiving_helpers.R"))
for (state in c("raj", "up")) {
  path <- here("data", "cohorts", paste0("receiving_", state, ".parquet"))
  cells <- arrow::read_parquet(path)
  cells$dose_main <- childhood_dose(cells$birth_year, cells, CYCLES[[state]])
  for (window in c("alt1", "alt2")) {
    cells[[paste0("dose_", window)]] <- childhood_dose(
      cells$birth_year, cells, CYCLES[[state]], EXPOSURE_WINDOWS[[window]]
    )
  }
  arrow::write_parquet(cells, path)
  write_audit(
    cells |> group_by(birth_year) |>
      summarise(
        n_cells = n(), n_missing = sum(is.na(dose_main)),
        mean_dose = mean(dose_main, na.rm = TRUE),
        max_dose = max(dose_main, na.rm = TRUE)
      ),
    paste0("receiving_", state, "_exposure.csv")
  )
}
