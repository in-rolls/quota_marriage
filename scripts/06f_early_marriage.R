# 06f_early_marriage.R
# Early-marriage margin: % of women married by age X as the outcome. Rolls
# record current status only (no age at marriage), so "married by X" is
# observable exactly for the cohort observed at age X; the battery is run
# within observation-age bands, the youngest usable band (19-21) being the
# closest census-scale analogue of under-age marriage. UP is attenuated by
# the roll-deletion lag and reported as secondary.

library(here)
library(dplyr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "06_estimation_helpers.R"))

all_tidy <- list()
band_summaries <- list()

NOTES_EARLY <- paste0(
    NOTES_SIGNIF,
    " Rolls record current marital status only, so ``married by age $X$'' is",
    " observable exactly for the cohort observed at age $X$; each column",
    " restricts to GP $\\times$ cohort cells in the stated observation-age",
    " band. Cells weighted by women counts; SEs clustered by GP.",
    " UP's relation field lags marriage by several years at young ages, so",
    " UP estimates on this margin are attenuated."
)

ANALYSIS_STATES <- Filter(function(s) file.exists(here("data", "cohorts",
    sprintf("analysis_%s.parquet", s))), c("raj", "up"))
for (state in ANALYSIS_STATES) {
    roll_year_actual <- readr::read_csv(
        here("data", "audit", sprintf("02b_%s_clean_stats.csv", state)),
        show_col_types = FALSE)$roll_year[1]

    cells <- arrow::read_parquet(
        here("data", "cohorts", sprintf("analysis_%s.parquet", state))) |>
        mutate(obs_age = roll_year_actual - birth_year)

    band_models <- list()
    for (band in names(OBS_AGE_BANDS)) {
        lo <- OBS_AGE_BANDS[[band]][1]
        hi <- OBS_AGE_BANDS[[band]][2]
        d <- cells |> filter(obs_age >= lo, obs_age <= hi)

        band_summaries[[paste(state, band)]] <- d |>
            summarise(
                n_cells = n(),
                n_gps = n_distinct(lgd_gp_code),
                mean_share_married = weighted.mean(share_married_w, n_women,
                                                   na.rm = TRUE),
                mean_dose = weighted.mean(dose_main, n_women, na.rm = TRUE),
                total_women = sum(n_women)
            ) |>
            mutate(state = .env$state, band = .env$band)

        # Within a 3-5 year observation band the GP-FE spec has no residual
        # dose variation, so bands use the cross-GP specs only; bands where
        # no cohort was exposed (dose identically 0) are summary-only.
        if (length(unique(d$dose_main[d$n_women > 0])) < 2) next
        castes_band <- paste(caste_controls(d), collapse = " + ")
        for (y in c("share_married_w", "natal_share_w")) {
            db <- d |> filter(!is.na(.data[[y]]), n_women > 0)
            m1 <- fixest::feols(as.formula(sprintf(
                    "%s ~ dose_main + %s | fe_district^birth_year", y, castes_band)),
                data = db, weights = ~n_women, cluster = ~lgd_gp_code)
            m2 <- fixest::feols(as.formula(sprintf(
                    "%s ~ dose_main + %s | fe_dist_block^birth_year", y, castes_band)),
                data = db, weights = ~n_women, cluster = ~lgd_gp_code)
            all_tidy[[paste(state, band, y)]] <- battery_tidy(
                list(s1 = m1, s2 = m2), state,
                paste0("early_marriage_", band), y)
            if (y == "share_married_w") band_models[[band]] <- m2
        }
    }

    # Zero-dose placebo: the oldest band has dose identically 0, so any
    # treatment coefficient there is a level artifact of the 2005 assignment,
    # and bounds how much of the younger bands' dose coefficients is real
    castes <- paste(caste_controls(cells), collapse = " + ")
    zb <- OBS_AGE_BANDS[[length(OBS_AGE_BANDS)]]
    d0 <- cells |>
        filter(obs_age >= zb[1], obs_age <= zb[2],
               !is.na(share_married_w), n_women > 0)
    m0 <- fixest::feols(
        as.formula(paste0("share_married_w ~ treat_2005 + treat_2010 + ", castes,
                          " | fe_dist_block^birth_year")),
        data = d0, weights = ~n_women, cluster = ~lgd_gp_code)
    all_tidy[[paste(state, "zero_dose_placebo")]] <- battery_tidy(
        list(zero_dose_band = m0), state, "early_marriage_placebo",
        "share_married_w")
    pooled <- cells |>
        filter(!is.na(share_married_w), n_women > 0, !is.na(obs_age)) |>
        mutate(band = cut(obs_age,
                          breaks = c(18, 21, 25, 30, 36),
                          labels = names(OBS_AGE_BANDS),
                          right = TRUE)) |>
        filter(!is.na(band))
    m_inter <- fixest::feols(
        as.formula(paste0("share_married_w ~ dose_main:band + ", castes,
                          " | fe_dist_block^birth_year")),
        data = pooled, weights = ~n_women, cluster = ~lgd_gp_code)
    inter_terms <- grep("^dose_main:band", names(coef(m_inter)), value = TRUE)
    all_tidy[[paste(state, "interaction")]] <- tibble(
        state = state, design = "early_marriage_interaction",
        outcome = "share_married_w", spec = "s2_interacted",
        term = inter_terms,
        estimate = coef(m_inter)[inter_terms],
        se = fixest::se(m_inter)[inter_terms],
        p = fixest::pvalue(m_inter)[inter_terms],
        n = stats::nobs(m_inter),
        r2 = fixest::fitstat(m_inter, "r2")[[1]]
    )

    aer_etable(
        band_models,
        file = here("tabs", sprintf("early_marriage_%s.tex", state)),
        dict = c(DICT_MAIN, FE_DICT_BATTERY),
        headers = as.list(setNames(rep(1, length(band_models)),
                                   paste0("Obs. age ", names(band_models)))),
        notes = NOTES_EARLY
    )
}

write_audit(bind_rows(all_tidy), "06f_early_marriage_estimates.csv")
write_audit(bind_rows(band_summaries), "06f_band_summaries.csv")
message("06f complete")
