# 00_utils.R
# Sections marked "vendored" are copied from quota_representation/scripts/00_utils.R and
# 05b_short_term_random_rotation.R @ c6900d1105170a1eece153ebbc7ca610250ba54d;
# Historical origin is recorded in Git; functions used by this study are maintained here.

library(stringi)
library(stringdist)
library(here)

# =============================================================================
# DUCKDB CONNECTION FACTORY
# =============================================================================

get_duck <- function() {
    con <- DBI::dbConnect(duckdb::duckdb())
    DBI::dbExecute(con, sprintf("SET memory_limit = '%s'", DUCKDB_MEMORY_LIMIT))
    DBI::dbExecute(con, sprintf("SET threads = %d", DUCKDB_THREADS))
    DBI::dbExecute(con, sprintf("SET temp_directory = '%s'", here("data", "tmp")))
    con
}

# =============================================================================
# AUDIT OUTPUT
# =============================================================================

write_audit <- function(df, filename) {
    path <- here("data", "audit", filename)
    readr::write_csv(df, path)
    message("Audit written: ", path, " (", nrow(df), " rows)")
    invisible(path)
}

# =============================================================================
# STRING NORMALIZATION (vendored)
# =============================================================================

make_match_key <- function(district, block, gp) {
    paste(tolower(trimws(district)), tolower(trimws(block)), tolower(trimws(gp)), sep = "_")
}

normalize_string <- function(input_string) {
     normalized_string <- stri_trans_general(input_string, "Latin-ASCII")
     normalized_string <- stri_trans_tolower(normalized_string)
     normalized_string <- gsub("\\s+", " ", normalized_string)
     normalized_string <- trimws(normalized_string)
     normalized_string <- gsub("[[:punct:]]", "", normalized_string)
     return(normalized_string)
}

normalize_string_strict <- function(input_string) {
    normalized_string <- stri_trans_general(input_string, "Latin-ASCII")
    normalized_string <- stri_trans_tolower(normalized_string)
    normalized_string <- gsub("[[:space:]]+", "", normalized_string)
    normalized_string <- gsub("[[:punct:]]", "", normalized_string)
    return(normalized_string)
}

# Devanagari-specific normalization: strip danda, zero-width joiners, and
# punctuation, and collapse whitespace, without transliterating. Punctuation
# must be removed with a Unicode-aware class: R's TRE [[:punct:]] treats
# Devanagari combining marks (vowel matras) as punctuation on UTF-8 input
# and shreds the names.
normalize_devanagari <- function(input_string) {
    s <- stri_replace_all_regex(input_string, "[\\u200b-\\u200d\\ufeff]", "")
    s <- stri_replace_all_regex(s, "[\\u0964\\u0965]", " ")
    s <- stri_trans_nfc(s)
    s <- stri_replace_all_regex(s, "\\p{P}", " ")
    s <- gsub("\\s+", " ", s)
    trimws(s)
}

# Vectorized best-match within blocks: for each row of `queries`, find the
# closest `candidates` string sharing the same block key. Returns one row per
# query with match index, distance, tie count, and runner-up distance.
match_best_in_block <- function(query_str, query_block, cand_str, cand_block,
                                threshold) {
    cand_split <- split(seq_along(cand_str), cand_block)
    n <- length(query_str)
    out <- data.frame(
        cand_idx = rep(NA_integer_, n),
        match_distance = rep(NA_real_, n),
        runner_up_distance = rep(NA_real_, n),
        tie_count = rep(NA_integer_, n)
    )
    for (i in seq_len(n)) {
        idx <- cand_split[[as.character(query_block[i])]]
        if (is.null(idx) || is.na(query_str[i])) next
        d <- stringdist::stringdist(query_str[i], cand_str[idx], method = "jw")
        best <- min(d)
        if (is.na(best) || best > threshold) next
        tied <- which(d == best)
        out$cand_idx[i] <- idx[tied[1]]
        out$match_distance[i] <- best
        out$tie_count[i] <- length(tied)
        if (length(d) > 1) {
            out$runner_up_distance[i] <- sort(d, partial = 2)[2]
        }
    }
    out
}

# =============================================================================
# T-TEST HELPERS (vendored)
# =============================================================================

#' Run t-tests comparing treatment vs control groups
#' @param data Data frame with treatment indicator and outcome variables
#' @param vars Character vector of variable names to test
#' @param labels Character vector of display labels for variables
#' @param treat_var Name of the treatment indicator variable (default "treat")
#' @param na_string String to return when test cannot be run (default "--")
#' @param digits Number of decimal places (default 2)
#' @return tibble with Variable, Open (mean), Quota (mean), Diff. (with stars)
run_t_tests <- function(data, vars, labels, treat_var = "treat",
                        na_string = "--", digits = 2) {
    fmt <- paste0("%.", digits, "f")
    purrr::map2_dfr(vars, labels, function(var, label) {
        d <- data %>% dplyr::filter(!is.na(.data[[var]]))

        if (nrow(d) == 0 || length(unique(d[[treat_var]])) < 2) {
            return(tibble::tibble(
                Variable = label,
                Open = na_string,
                Quota = na_string,
                `Diff.` = na_string
            ))
        }

        fml <- stats::reformulate(treat_var, var)
        test <- stats::t.test(fml, data = d)
        stars <- dplyr::case_when(
            test$p.value < 0.01 ~ "$^{***}$",
            test$p.value < 0.05 ~ "$^{**}$",
            test$p.value < 0.1 ~ "$^{*}$",
            TRUE ~ ""
        )
        tibble::tibble(
            Variable = label,
            Open = sprintf(fmt, test$estimate[1]),
            Quota = sprintf(fmt, test$estimate[2]),
            `Diff.` = paste0(sprintf(fmt, test$estimate[1] - test$estimate[2]), stars)
        )
    })
}
