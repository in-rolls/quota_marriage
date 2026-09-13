# 07a_balance.R
# Census 2001 covariate balance by treatment on the bridged analysis sample
# (quota_representation 04d approach: normalized shares, t-tests).

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    bridge <- arrow::read_parquet(
        here("data", "bridge", sprintf("ps_treatment_%s.parquet", state)))

    gps <- bridge |>
        distinct(lgd_gp_code, treat_2005, treat_2010,
                 across(starts_with("pc01_"))) |>
        mutate(
            log_pop = log1p(as.numeric(pc01_pca_tot_p)),
            share_f = as.numeric(pc01_pca_tot_f) / as.numeric(pc01_pca_tot_p),
            lit_rate = as.numeric(pc01_pca_p_lit) / as.numeric(pc01_pca_tot_p),
            f_lit_rate = as.numeric(pc01_pca_f_lit) /
                pmax(as.numeric(pc01_pca_tot_f), 1),
            work_rate = as.numeric(pc01_pca_tot_work_p) /
                pmax(as.numeric(pc01_pca_tot_p), 1)
        )

    vars <- c("log_pop", "share_f", "lit_rate", "f_lit_rate", "work_rate")
    labels <- c("Log population (2001)", "Female share (2001)",
                "Literacy rate (2001)", "Female literacy rate (2001)",
                "Work participation (2001)")

    bal_05 <- run_t_tests(gps, vars, labels, treat_var = "treat_2005")
    bal_10 <- run_t_tests(gps, vars, labels, treat_var = "treat_2010")

    write_audit(bal_05 |> mutate(treatment = "treat_2005"),
                sprintf("07a_%s_balance_2005.csv", state))
    write_audit(bal_10 |> mutate(treatment = "treat_2010"),
                sprintf("07a_%s_balance_2010.csv", state))

    make_balance_out <- bind_rows(
        bal_05 |> mutate(Quota_year = "2005"),
        bal_10 |> mutate(Quota_year = "2010")
    )
    readr::write_csv(make_balance_out,
                     here("tabs", sprintf("balance_%s.csv", state)))

    # Design-consistent balance: within block, conditional on the seat's
    # caste-reservation stratum (raw t-tests conflate the caste strata)
    gps_fe <- bridge |>
        distinct(lgd_gp_code, treat_2005, treat_2010, fe_dist_block,
                 sc_2005, st_2005, obc_2005, sc_2010, st_2010, obc_2010,
                 across(starts_with("pc01_"))) |>
        mutate(
            log_pop = log1p(as.numeric(pc01_pca_tot_p)),
            lit_rate = as.numeric(pc01_pca_p_lit) / as.numeric(pc01_pca_tot_p),
            f_lit_rate = as.numeric(pc01_pca_f_lit) /
                pmax(as.numeric(pc01_pca_tot_f), 1)
        )
    cond_bal <- purrr::map_dfr(c("log_pop", "lit_rate", "f_lit_rate"), function(v) {
        m <- fixest::feols(
            as.formula(paste0(v, " ~ treat_2005 + treat_2010 + sc_2005 + st_2005 +",
                              " obc_2005 + sc_2010 + st_2010 + obc_2010 | fe_dist_block")),
            data = gps_fe, cluster = ~lgd_gp_code)
        tibble::tibble(
            covar = v,
            term = c("treat_2005", "treat_2010"),
            estimate = coef(m)[c("treat_2005", "treat_2010")],
            se = fixest::se(m)[c("treat_2005", "treat_2010")],
            p = fixest::pvalue(m)[c("treat_2005", "treat_2010")]
        )
    })
    write_audit(cond_bal |> mutate(state = state),
                sprintf("07a_%s_balance_conditional.csv", state))
}

message("07a complete")
