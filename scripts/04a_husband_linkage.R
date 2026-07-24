# 04a_husband_linkage.R
# Link each married woman (relation_type == 'husband') to her husband among
# male electors in the same household (same source PDF + cleaned house number).
# Scoring: exact Devanagari name match wins (distance 0), else Jaro-Winkler on
# transliterated names. Accept best <= JW_HUSBAND with a JW_HUSBAND_MARGIN
# runner-up margin (or a single candidate). No age-gap filter: the gap is the
# outcome; implausible gaps are flagged, not dropped.

library(here)
library(dplyr)
library(DBI)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

con <- get_duck()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (state in c("raj", "up")) {
    electors_dir <- here("data", "electors", state)
    if (!file.exists(file.path(electors_dir, ".clean_complete"))) {
        message("Electors not yet cleaned, skipping: ", state)
        next
    }
    out_dir <- here("data", "couples", state)
    dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
    done_flag <- file.path(out_dir, ".linkage_complete")
    if (file.exists(done_flag)) {
        message("Already linked, skipping: ", state)
        next
    }

    districts <- list.dirs(electors_dir, recursive = FALSE, full.names = FALSE)
    districts <- districts[grepl("^district_part=", districts)]
    message(sprintf("%s: linking couples in %d district chunks", state, length(districts)))

    stats <- list()

    for (dp in districts) {
        chunk_out <- file.path(out_dir, paste0(sub("^district_part=", "", dp), ".parquet"))
        if (file.exists(chunk_out)) next
        chunk_glob <- file.path(electors_dir, dp, "*.parquet")

        pairs <- dbGetQuery(con, sprintf("
            SELECT
                w.elector_uid AS wife_uid,
                w.filename, w.house_no_clean,
                w.age AS wife_age, w.birth_year AS wife_birth_year,
                w.rel_name_dev, w.rel_name_std,
                m.elector_uid AS husband_uid,
                m.age AS husband_age,
                m.name_dev AS husband_name_dev,
                m.name_std AS husband_name_std
            FROM read_parquet(%s) w
            JOIN read_parquet(%s) m
              ON w.filename = m.filename
             AND w.house_no_clean = m.house_no_clean
            WHERE w.sex_std = 'f'
              AND w.relation_type = 'husband'
              AND w.house_no_clean IS NOT NULL
              AND m.sex_std = 'm'",
            dbQuoteString(con, chunk_glob), dbQuoteString(con, chunk_glob)))

        n_married_with_hh <- dbGetQuery(con, sprintf("
            SELECT count(*) AS n
            FROM read_parquet(%s)
            WHERE sex_std = 'f' AND relation_type = 'husband'
              AND house_no_clean IS NOT NULL",
            dbQuoteString(con, chunk_glob)))$n

        if (nrow(pairs) == 0) {
            stats[[dp]] <- tibble(district_part = dp,
                                  n_married_with_hh = n_married_with_hh,
                                  n_pairs = 0L, n_linked = 0L)
            next
        }

        dev_exact <- !is.na(pairs$rel_name_dev) & !is.na(pairs$husband_name_dev) &
            pairs$rel_name_dev != "" & pairs$rel_name_dev == pairs$husband_name_dev
        d_std <- stringdist::stringdist(pairs$rel_name_std, pairs$husband_name_std,
                                        method = "jw")
        pairs$dist <- ifelse(dev_exact, 0, d_std)

        scored <- pairs |>
            filter(!is.na(dist)) |>
            group_by(wife_uid) |>
            arrange(dist, husband_uid, .by_group = TRUE) |>
            summarise(
                filename = first(filename),
                house_no_clean = first(house_no_clean),
                wife_age = first(wife_age),
                wife_birth_year = first(wife_birth_year),
                husband_uid = first(husband_uid),
                husband_age = first(husband_age),
                match_distance = first(dist),
                runner_up = if (n() > 1) nth(dist, 2) else NA_real_,
                n_candidates = n(),
                .groups = "drop"
            ) |>
            filter(
                match_distance <= JW_HUSBAND,
                n_candidates == 1 | is.na(runner_up) |
                    (runner_up - match_distance) >= JW_HUSBAND_MARGIN
            ) |>
            group_by(husband_uid) |>
            mutate(husband_contested = n() > 1) |>
            ungroup() |>
            mutate(
                gap = husband_age - wife_age,
                gap_implausible = !is.na(gap) & (gap < -15 | gap > 40),
                district_part = sub("^district_part=", "", dp),
                state = state
            )

        arrow::write_parquet(scored, chunk_out)

        stats[[dp]] <- tibble(
            district_part = dp,
            n_married_with_hh = n_married_with_hh,
            n_pairs = nrow(pairs),
            n_linked = nrow(scored)
        )
    }

    # Recompute the audit over ALL chunks (earlier runs may have written some)
    couples_files <- list.files(out_dir, pattern = "\\.parquet$", full.names = TRUE)
    linkage_stats <- dbGetQuery(con, sprintf("
        SELECT district_part,
               count(*) AS n_linked
        FROM read_parquet(%s)
        GROUP BY district_part",
        dbQuoteString(con, file.path(out_dir, "*.parquet")))) |>
        left_join(
            dbGetQuery(con, sprintf("
                SELECT district_part, count(*) AS n_married_with_hh
                FROM read_parquet(%s, hive_partitioning = true)
                WHERE sex_std = 'f' AND relation_type = 'husband'
                  AND house_no_clean IS NOT NULL
                GROUP BY district_part",
                dbQuoteString(con, file.path(electors_dir, "*", "*.parquet")))),
            by = "district_part") |>
        mutate(linkage_rate = n_linked / pmax(n_married_with_hh, 1))
    write_audit(linkage_stats, sprintf("04a_%s_linkage_stats.csv", state))

    couples_glob <- file.path(out_dir, "*.parquet")
    gap_dist <- dbGetQuery(con, sprintf("
        SELECT wife_birth_year,
               count(*) AS n_couples,
               avg(gap) AS mean_gap,
               median(gap) AS med_gap,
               quantile_cont(gap, 0.10) AS p10,
               quantile_cont(gap, 0.90) AS p90,
               avg(CASE WHEN gap < 0 THEN 1.0 ELSE 0 END) AS share_negative,
               avg(CASE WHEN gap_implausible THEN 1.0 ELSE 0 END) AS share_implausible,
               avg(CASE WHEN husband_contested THEN 1.0 ELSE 0 END) AS share_contested
        FROM read_parquet(%s)
        WHERE husband_age IS NOT NULL AND wife_age IS NOT NULL
        GROUP BY wife_birth_year ORDER BY wife_birth_year",
        dbQuoteString(con, couples_glob)))
    write_audit(gap_dist, sprintf("04a_%s_gap_distribution.csv", state))

    overall_rate <- sum(linkage_stats$n_linked) / max(sum(linkage_stats$n_married_with_hh), 1)
    message(sprintf("%s linkage rate: %.1f%%", state, 100 * overall_rate))
    if (overall_rate < 0.60) {
        warning(sprintf("%s: linkage rate %.1f%% is below 60%% — inspect house_no_clean and name normalization",
                        state, 100 * overall_rate))
    }

    file.create(done_flag)
}

message("04a complete")
