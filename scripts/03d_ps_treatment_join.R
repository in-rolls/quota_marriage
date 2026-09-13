# 03d_ps_treatment_join.R
# Join polling-station bridges to the shared election histories on lgd_gp_code.
# The 2005-2010 panels supply the broadest coverage; 2015 reservation is
# attached from the four-cycle panels where available.

library(here)
library(dplyr)
library(readr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "00_utils.R"))

BALANCE_COVARS <- c("pc01_pca_tot_p", "pc01_pca_tot_f", "pc01_pca_tot_m",
                    "pc01_pca_p_lit", "pc01_pca_f_lit", "pc01_pca_m_lit",
                    "pc01_pca_tot_work_p", "pc01_pca_tot_work_f")

load_treatment <- function(state) {
    if (state == "raj") {
        panel <- treatment_panel("raj", four_cycle = FALSE) |>
            transmute(
                lgd_gp_code, lgd_gp_name_panel = lgd_gp_name, lgd_block_code,
                treat_2005, treat_2010,
                sc_2005, st_2005, obc_2005, sc_2010, st_2010, obc_2010,
                fe_district = district_std_2010,
                fe_dist_block = dist_samiti_2010,
                panel_match_distance = match_distance,
                across(any_of(BALANCE_COVARS))
            )
        panel4 <- treatment_panel("raj", four_cycle = TRUE) |>
            select(lgd_gp_code, treat_2015, count_treated) |>
            filter(!is.na(lgd_gp_code)) |>
            distinct(lgd_gp_code, .keep_all = TRUE)
    } else {
        panel <- treatment_panel("up", four_cycle = FALSE) |>
            transmute(
                lgd_gp_code, lgd_gp_name_panel = lgd_gp_name, lgd_block_code,
                treat_2005, treat_2010,
                obc_2005, obc_2010,
                sc_2005 = dalit_2005, sc_2010 = dalit_2010,
                st_2005 = as.integer(grepl("Scheduled Tribe", gp_res_status_fin_eng_2005)),
                st_2010 = as.integer(grepl("Scheduled Tribe", gp_res_status_fin_eng_2010)),
                fe_district = district_name_eng_2010,
                fe_dist_block = dist_block_2010,
                panel_match_distance = match_distance,
                across(any_of(BALANCE_COVARS))
            )
        panel4 <- treatment_panel("up", four_cycle = TRUE) |>
            select(lgd_gp_code, treat_2015, count_treated) |>
            filter(!is.na(lgd_gp_code)) |>
            distinct(lgd_gp_code, .keep_all = TRUE)
    }

    n_before <- nrow(panel)
    panel <- panel |>
        filter(!is.na(lgd_gp_code), !is.na(treat_2005), !is.na(treat_2010)) |>
        arrange(lgd_gp_code, panel_match_distance) |>
        distinct(lgd_gp_code, .keep_all = TRUE) |>
        left_join(panel4, by = "lgd_gp_code")

    list(panel = panel, n_dropped_dedup = n_before - nrow(panel))
}

for (state in c("raj", "up")) {
    if (!file.exists(here("data", "bridge", sprintf("ps_gp_xwalk_%s.parquet", state)))) {
        message("Bridge not yet built, skipping: ", state)
        next
    }
    bridge <- arrow::read_parquet(
        here("data", "bridge", sprintf("ps_gp_xwalk_%s.parquet", state)))
    tr <- load_treatment(state)

    joined <- bridge |>
        inner_join(tr$panel, by = "lgd_gp_code")

    arrow::write_parquet(joined,
        here("data", "bridge", sprintf("ps_treatment_%s.parquet", state)))

    coverage <- bridge |>
        mutate(has_treatment = lgd_gp_code %in% tr$panel$lgd_gp_code) |>
        group_by(district_std) |>
        summarise(
            n_parts_bridged = n(),
            n_parts_with_treatment = sum(has_treatment),
            share_parts_with_treatment = mean(has_treatment),
            electors_bridged = sum(n_electors),
            electors_with_treatment = sum(n_electors[has_treatment]),
            .groups = "drop"
        )
    write_audit(coverage, sprintf("03d_%s_treatment_coverage.csv", state))
    write_audit(
        tibble(state = state,
               n_panel_gps = nrow(tr$panel),
               n_dropped_dedup = tr$n_dropped_dedup,
               n_bridged_parts = nrow(bridge),
               n_parts_with_treatment = nrow(joined),
               n_gps_observed_in_rolls = n_distinct(joined$lgd_gp_code)),
        sprintf("03d_%s_join_summary.csv", state))

    message(sprintf(
        "03d %s: %d parts with treatment (%d GPs); %d panel GPs available",
        state, nrow(joined), n_distinct(joined$lgd_gp_code), nrow(tr$panel)))
}

message("03d complete")
