# 03e_audit_bridge_balance.R
# Selection tests on the bridge: is being observed in the rolls (bridged to a
# polling part) correlated with treatment? A significant coefficient is a
# stop-and-investigate condition for the whole design.

library(here)
library(dplyr)
library(fixest)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "00_utils.R"))

results <- list()

for (state in c("raj", "up")) {
    if (!file.exists(here("data", "bridge", sprintf("ps_treatment_%s.parquet", state)))) {
        message("Treatment join not yet built, skipping: ", state)
        next
    }
    panel <- treatment_panel(state)
    if (state == "raj") {
        panel <- panel |> mutate(fe_dist_block = dist_samiti_2010)
    } else {
        panel <- panel |> mutate(fe_dist_block = dist_block_2010)
    }
    panel <- panel |>
        filter(!is.na(lgd_gp_code), !is.na(treat_2005), !is.na(treat_2010)) |>
        arrange(lgd_gp_code, match_distance) |>
        distinct(lgd_gp_code, .keep_all = TRUE)

    joined <- arrow::read_parquet(
        here("data", "bridge", sprintf("ps_treatment_%s.parquet", state)))

    gp_rolls <- joined |>
        group_by(lgd_gp_code) |>
        summarise(n_parts = n(), n_electors = sum(n_electors), .groups = "drop")

    panel <- panel |>
        left_join(gp_rolls, by = "lgd_gp_code") |>
        mutate(
            matched_to_rolls = as.integer(!is.na(n_parts)),
            log_electors = log1p(coalesce(n_electors, 0))
        )

    m1 <- feols(matched_to_rolls ~ treat_2005 + treat_2010 | fe_dist_block,
                data = panel, cluster = ~lgd_gp_code)
    m2 <- feols(log_electors ~ treat_2005 + treat_2010 | fe_dist_block,
                data = panel |> filter(matched_to_rolls == 1),
                cluster = ~lgd_gp_code)

    results[[state]] <- tibble(
        state = state,
        outcome = c("matched_to_rolls", "matched_to_rolls",
                    "log_electors_bridged", "log_electors_bridged"),
        term = rep(c("treat_2005", "treat_2010"), 2),
        estimate = c(coef(m1)[["treat_2005"]], coef(m1)[["treat_2010"]],
                     coef(m2)[["treat_2005"]], coef(m2)[["treat_2010"]]),
        se = c(se(m1)[["treat_2005"]], se(m1)[["treat_2010"]],
               se(m2)[["treat_2005"]], se(m2)[["treat_2010"]]),
        p = c(pvalue(m1)[["treat_2005"]], pvalue(m1)[["treat_2010"]],
              pvalue(m2)[["treat_2005"]], pvalue(m2)[["treat_2010"]]),
        mean_outcome = c(rep(mean(panel$matched_to_rolls), 2),
                         rep(mean(panel$log_electors[panel$matched_to_rolls == 1]), 2)),
        n = c(rep(nobs(m1), 2), rep(nobs(m2), 2))
    )

    covars <- intersect(
        c("pc01_pca_tot_p", "pc01_pca_tot_f", "pc01_pca_p_lit", "pc01_pca_f_lit"),
        names(panel))
    bal <- panel |>
        mutate(across(all_of(covars), as.numeric)) |>
        run_t_tests(vars = covars, labels = covars,
                    treat_var = "matched_to_rolls")
    write_audit(bal, sprintf("03e_%s_bridged_vs_unbridged.csv", state))
}

balance_tbl <- bind_rows(results)
write_audit(balance_tbl, "03e_bridge_balance.csv")

flagged <- balance_tbl |> filter(outcome == "matched_to_rolls", p < 0.05)
if (nrow(flagged) > 0) {
    warning("Bridge success correlates with treatment (STOP AND INVESTIGATE):\n",
            paste(sprintf("  %s %s: b=%.4f p=%.4f", flagged$state, flagged$term,
                          flagged$estimate, flagged$p), collapse = "\n"))
} else {
    message("Bridge balance OK: no treatment-match correlation at p<0.05")
}

message("03e complete")
