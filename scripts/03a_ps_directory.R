# 03a_ps_directory.R
# One row per polling part (source PDF), with ranked candidate village strings
# extracted from the polling-station name/address and main town, in both
# Devanagari and transliteration.

library(here)
library(dplyr)
library(tidyr)
library(stringr)
library(DBI)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "03_bridge_helpers.R"))

stopwords <- readr::read_csv(here("data-raw", "ps_stopwords.csv"),
                             show_col_types = FALSE)
stop_dev <- stopwords$token[stopwords$script == "dev"]
stop_lat <- stopwords$token[stopwords$script == "latin"]

strip_tokens <- function(x, tokens) {
    toks <- str_split(x, "\\s+")
    vapply(toks, function(t) {
        t <- t[!t %in% tokens & nchar(t) > 1]
        paste(t, collapse = " ")
    }, character(1))
}

# Candidate villages, in priority order:
#   1. main_town (the roll's own village/town field)
#   2. polling-station name with institution tokens stripped
#   3. polling-station address with institution tokens stripped
extract_candidates <- function(df, town_col, ps_col, addr_col, tokens, normalizer) {
    cand1 <- normalizer(df[[town_col]])
    cand2 <- strip_tokens(normalizer(df[[ps_col]]), tokens)
    cand3 <- strip_tokens(normalizer(df[[addr_col]]), tokens)
    empty_to_na <- function(x) ifelse(is.na(x) | x == "", NA_character_, x)
    tibble(cand_1 = empty_to_na(cand1),
           cand_2 = empty_to_na(cand2),
           cand_3 = empty_to_na(cand3))
}

con <- get_duck()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (state in c("raj", "up")) {
    if (!file.exists(here("data", "electors", state, ".clean_complete"))) {
        message("Electors not yet cleaned, skipping: ", state)
        next
    }
    electors_glob <- here("data", "electors", state, "*", "*.parquet")
    rolls_glob <- here("data", "rolls", state, "*", "*.parquet")

    ps <- dbGetQuery(con, sprintf("
        SELECT
            any_value(district) AS district_dev,
            any_value(district_t13n) AS district_t13n,
            filename,
            any_value(ac_name) AS ac_name_dev,
            any_value(ac_name_t13n) AS ac_name_t13n,
            any_value(main_town) AS main_town_dev,
            any_value(main_town_t13n) AS main_town_t13n,
            any_value(mandal) AS mandal_dev,
            any_value(mandal_t13n) AS mandal_t13n,
            any_value(polling_station_name) AS ps_name_dev,
            any_value(polling_station_name_t13n) AS ps_name_t13n,
            any_value(polling_station_address) AS ps_addr_dev,
            any_value(polling_station_address_t13n) AS ps_addr_t13n,
            count(*) AS n_electors
        FROM read_parquet(%s, hive_partitioning = true)
        GROUP BY filename",
        dbQuoteString(con, rolls_glob)))

    message(sprintf("%s: %d polling parts", state, nrow(ps)))

    dev_cands <- extract_candidates(ps, "main_town_dev", "ps_name_dev",
                                    "ps_addr_dev", stop_dev,
                                    normalize_devanagari) |>
        mutate(across(everything(), clean_candidate_dev)) |>
        rename_with(~ paste0("village_", .x, "_dev"))
    std_cands <- extract_candidates(ps, "main_town_t13n", "ps_name_t13n",
                                    "ps_addr_t13n", stop_lat,
                                    normalize_string) |>
        mutate(across(everything(), clean_candidate_std)) |>
        rename_with(~ paste0("village_", .x, "_std"))

    longest_token <- function(x) {
        vapply(str_split(coalesce(x, ""), "\\s+"), function(t) {
            t <- t[nchar(t) >= 4]
            if (length(t) == 0) NA_character_ else t[which.max(nchar(t))]
        }, character(1))
    }

    ps_dir <- ps |>
        mutate(
            state = state,
            district_std = normalize_string(district_t13n),
            mandal_std = normalize_string(mandal_t13n)
        ) |>
        bind_cols(dev_cands, std_cands) |>
        mutate(
            village_cand_4_std = ifelse(
                grepl(" ", village_cand_2_std),
                longest_token(village_cand_2_std),
                NA_character_),
            village_cand_4_dev = NA_character_
        ) |>
        mutate(
            has_candidate = !is.na(village_cand_1_dev) | !is.na(village_cand_2_dev) |
                            !is.na(village_cand_1_std) | !is.na(village_cand_2_std)
        )

    arrow::write_parquet(ps_dir,
        here("data", "bridge", sprintf("ps_directory_%s.parquet", state)))

    extract_stats <- ps_dir |>
        group_by(district_std) |>
        summarise(
            n_parts = n(),
            n_electors = sum(n_electors),
            share_with_candidate = mean(has_candidate),
            share_with_main_town = mean(!is.na(village_cand_1_dev) | !is.na(village_cand_1_std)),
            .groups = "drop"
        )
    write_audit(extract_stats, sprintf("03a_%s_ps_extract_stats.csv", state))

    set.seed(42)
    sample_rows <- ps_dir |>
        select(district_std, ps_name_t13n, main_town_t13n,
               village_cand_1_std, village_cand_2_std, village_cand_3_std) |>
        slice_sample(n = min(500, nrow(ps_dir)))
    write_audit(sample_rows, sprintf("03a_%s_ps_extract_sample.csv", state))
}

message("03a complete")
