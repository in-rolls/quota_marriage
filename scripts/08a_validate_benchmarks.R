# 08a_validate_benchmarks.R
# Face validity of the constructed outcomes against external benchmarks:
# current-status marriage curves vs NFHS-4, spousal-gap distribution, sex
# ratios by age, and natal-share curves.

library(here)
library(dplyr)
library(tidyr)
library(ggplot2)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

benchmarks <- readr::read_csv(here("data-raw", "nfhs4_benchmarks.csv"),
                              show_col_types = FALSE)

dir.create(here("figs", "validation"), showWarnings = FALSE)

validation_summary <- list()

for (state in c("raj", "up")) {
    rel_by_age <- readr::read_csv(
        here("data", "audit", sprintf("02b_%s_relation_by_age.csv", state)),
        show_col_types = FALSE)

    marriage_curve <- rel_by_age |>
        filter(sex_std == "f", age <= 49) |>
        group_by(age) |>
        summarise(
            share_married = sum(n[relation_type == "husband"], na.rm = TRUE) / sum(n),
            share_natal = sum(n[relation_type == "father"], na.rm = TRUE) / sum(n),
            n = sum(n), .groups = "drop"
        )

    fig1 <- ggplot(marriage_curve, aes(age)) +
        geom_line(aes(y = share_married, color = "Listed under husband")) +
        geom_line(aes(y = share_natal, color = "Listed under father")) +
        scale_color_manual(values = unname(COLORS_PUB[c("primary", "accent")])) +
        labs(x = "Age in roll", y = "Share of women",
             title = sprintf("Marriage status by age, %s rolls", toupper(state)),
             color = NULL) +
        theme_pub()
    ggsave(here("figs", "validation", sprintf("marriage_curve_%s.pdf", state)),
           fig1, width = FIG_WIDTH_FULL, height = FIG_HEIGHT)

    sex_ratio <- rel_by_age |>
        group_by(age) |>
        summarise(
            f_per_100m = 100 * sum(n[sex_std == "f"]) / pmax(sum(n[sex_std == "m"]), 1),
            .groups = "drop")
    fig2 <- ggplot(sex_ratio |> filter(age <= 60), aes(age, f_per_100m)) +
        geom_line(color = COLORS_PUB[["primary"]]) +
        geom_hline(yintercept = 100, linetype = "dashed", color = "gray50") +
        labs(x = "Age in roll", y = "Women per 100 men") +
        theme_pub()
    ggsave(here("figs", "validation", sprintf("sex_ratio_%s.pdf", state)),
           fig2, width = FIG_WIDTH_FULL, height = FIG_HEIGHT)

    gap_dist <- readr::read_csv(
        here("data", "audit", sprintf("04a_%s_gap_distribution.csv", state)),
        show_col_types = FALSE)
    overall_med_gap <- with(gap_dist, sum(med_gap * n_couples) / sum(n_couples))
    share_negative <- with(gap_dist, sum(share_negative * n_couples) / sum(n_couples))

    share_married_18 <- marriage_curve$share_married[marriage_curve$age == 18]
    share_married_25 <- marriage_curve$share_married[marriage_curve$age == 25]

    bm <- benchmarks |> filter(state == !!state)
    validation_summary[[state]] <- tibble(
        state = state,
        metric = c("share_married_age18", "share_married_age25",
                   "median_spousal_gap", "share_negative_gap"),
        rolls_value = c(share_married_18, share_married_25,
                        overall_med_gap, share_negative),
        benchmark = c(NA_real_, NA_real_,
                      bm$value[bm$metric == "median_spousal_gap"], 0.05),
        check = c("NFHS current-status curves rise steeply 18-25",
                  "should approach 0.9 by mid-20s (NFHS-4)",
                  "NFHS/IHDS rural median 4-5",
                  "should be < 0.05")
    )
}

summary_tbl <- bind_rows(validation_summary)
write_audit(summary_tbl, "08a_validation_summary.csv")
print(summary_tbl, n = Inf)

message("08a complete — inspect figs/validation/ and 08a_validation_summary.csv")
