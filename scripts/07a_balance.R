# 07a_balance.R
# Census 2001 covariate balance by treatment on the bridged analysis sample
# (quota_raj 04d approach: normalized shares, t-tests).

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

for (state in c("raj", "up")) {
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
}

message("07a complete")
