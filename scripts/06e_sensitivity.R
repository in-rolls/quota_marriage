# 06e_sensitivity.R
# Specification curve over: exposure window (5-15 / 6-16 / 10-16), bridge
# match quality (all matches vs exact-only vs distance <= 0.10), natal
# definition (father vs father+mother), and couples sample (all vs clean).

library(here)
library(dplyr)
library(tidyr)
library(ggplot2)
library(fixest)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

run_spec <- function(cells, y, treat_var, wvar, label, state) {
    d <- cells |> filter(!is.na(.data[[y]]), .data[[wvar]] > 0)
    m <- feols(as.formula(sprintf("%s ~ %s | lgd_gp_code + fe_district^birth_year",
                                  y, treat_var)),
               data = d, weights = as.formula(paste0("~", wvar)),
               cluster = ~lgd_gp_code)
    tibble(state = state, spec_label = label, outcome = y, term = treat_var,
           estimate = coef(m)[[treat_var]], se = se(m)[[treat_var]],
           p = pvalue(m)[[treat_var]], n = nobs(m))
}

all_specs <- list()

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state)))

    bridge <- arrow::read_parquet(
        here("data", "bridge", sprintf("ps_treatment_%s.parquet", state)))
    gp_quality <- bridge |>
        group_by(lgd_gp_code) |>
        summarise(min_bridge_distance = min(match_distance),
                  all_exact = all(match_distance == 0), .groups = "drop")
    cells <- cells |> left_join(gp_quality, by = "lgd_gp_code")

    for (y in c("mean_gap", "natal_share_w", "natal_ratio")) {
        wvar <- if (y == "mean_gap") "n_couples" else "n_women"

        for (w in c("dose_main", "dose_alt1", "dose_alt2")) {
            all_specs[[paste(state, y, w)]] <-
                run_spec(cells, y, w, wvar, paste0("window_", w), state)
        }
        all_specs[[paste(state, y, "exact_bridge")]] <-
            run_spec(cells |> filter(all_exact), y, "dose_main", wvar,
                     "bridge_exact_only", state)
        all_specs[[paste(state, y, "tight_bridge")]] <-
            run_spec(cells |> filter(min_bridge_distance <= 0.10), y,
                     "dose_main", wvar, "bridge_dist_le_010", state)
    }

    all_specs[[paste(state, "natal_fm")]] <-
        run_spec(cells, "natal_share_w_fm", "dose_main", "n_women",
                 "natal_father_plus_mother", state)
    all_specs[[paste(state, "gap_clean")]] <-
        run_spec(cells |> mutate(mean_gap = mean_gap_clean), "mean_gap",
                 "dose_main", "n_couples", "couples_clean_only", state)
}

spec_tbl <- bind_rows(all_specs)
write_audit(spec_tbl, "06e_sensitivity_estimates.csv")

fig <- spec_tbl |>
    mutate(spec_id = paste(spec_label, outcome)) |>
    ggplot(aes(x = estimate, y = spec_id, color = state)) +
    geom_point(position = position_dodge(width = 0.5)) +
    geom_errorbarh(aes(xmin = estimate - 1.96 * se, xmax = estimate + 1.96 * se),
                   height = 0.2, position = position_dodge(width = 0.5)) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray50") +
    facet_wrap(~outcome, scales = "free") +
    scale_color_manual(values = unname(COLORS_PUB[c("primary", "accent")])) +
    labs(x = "Exposure-dose coefficient (GP FE + district x cohort FE)",
         y = NULL, color = "State") +
    theme_pub()

ggsave(here("figs", "sensitivity_spec_curve.pdf"), fig,
       width = FIG_WIDTH_FULL * 1.4, height = FIG_HEIGHT * 1.2)

message("06e complete")
