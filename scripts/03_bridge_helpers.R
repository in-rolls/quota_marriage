# 03_bridge_helpers.R
# Shared machinery for the polling-part -> village -> LGD GP bridge (03b, 03c).

# The roll PDFs' district headers carry OCR junk prefixes ("ः ", "हि ", "ह ",
# stray digits). Strip leading tokens of <= 2 characters and stray digit runs,
# keeping the longest tail that looks like a name.
clean_district_dev <- function(x) {
    x <- normalize_devanagari(x)
    for (i in 1:3) {
        x <- sub("^\\S{1,2}\\s+", "", x)
        x <- sub("^[0-9०-९]+\\s*", "", x)
    }
    trimws(x)
}

# Map cleaned Devanagari district names to reference (latin) district names
# via ICU transliteration + JW fuzzy, with manual overrides (CSV columns
# roll_district, ref_district; roll_district holds the cleaned Devanagari
# string or its transliteration) taking precedence.
build_district_map_dev <- function(dev_names, ref_districts, override_path,
                                   threshold = 0.30) {
    ref_districts <- sort(unique(ref_districts[!is.na(ref_districts)]))
    map <- tibble(district_dev_clean = sort(unique(dev_names[!is.na(dev_names) &
                                                             dev_names != ""]))) |>
        mutate(
            translit = normalize_string(
                stringi::stri_trans_general(district_dev_clean, "Devanagari-Latin")),
            ref_district = NA_character_,
            match_method = NA_character_
        )
    for (i in seq_len(nrow(map))) {
        d <- stringdist::stringdist(map$translit[i], ref_districts, method = "jw")
        if (min(d) <= threshold) {
            map$ref_district[i] <- ref_districts[which.min(d)]
            map$match_method[i] <- sprintf("fuzzy_%.3f", min(d))
        }
    }
    if (file.exists(override_path)) {
        overrides <- readr::read_csv(override_path, show_col_types = FALSE)
        for (j in seq_len(nrow(overrides))) {
            k <- which(map$district_dev_clean == overrides$roll_district[j] |
                       map$translit == overrides$roll_district[j])
            if (length(k) >= 1) {
                map$ref_district[k] <- overrides$ref_district[j]
                map$match_method[k] <- "manual"
            }
        }
    }
    map
}

# Map roll district names to reference district names: exact on normalized
# strings, then JW fuzzy, with optional manual overrides (a CSV with columns
# roll_district, ref_district) taking precedence.
build_district_map <- function(roll_districts, ref_districts, override_path,
                               threshold = 0.25) {
    roll_districts <- sort(unique(roll_districts[!is.na(roll_districts)]))
    ref_districts <- sort(unique(ref_districts[!is.na(ref_districts)]))

    map <- tibble(roll_district = roll_districts) |>
        mutate(
            ref_district = ifelse(roll_district %in% ref_districts,
                                  roll_district, NA_character_),
            match_method = ifelse(!is.na(ref_district), "exact", NA_character_)
        )

    unmatched <- which(is.na(map$ref_district))
    for (i in unmatched) {
        d <- stringdist::stringdist(map$roll_district[i], ref_districts, method = "jw")
        if (min(d) <= threshold) {
            map$ref_district[i] <- ref_districts[which.min(d)]
            map$match_method[i] <- sprintf("fuzzy_%.3f", min(d))
        }
    }

    if (file.exists(override_path)) {
        overrides <- readr::read_csv(override_path, show_col_types = FALSE)
        for (j in seq_len(nrow(overrides))) {
            k <- which(map$roll_district == overrides$roll_district[j])
            if (length(k) == 1) {
                map$ref_district[k] <- overrides$ref_district[j]
                map$match_method[k] <- "manual"
            } else {
                map <- bind_rows(map, tibble(
                    roll_district = overrides$roll_district[j],
                    ref_district = overrides$ref_district[j],
                    match_method = "manual"))
            }
        }
    }
    map
}

# Transliterated candidate cleanup: polling-station names arrive with the
# part number glued on ("192dhaanaa") and stray non-Latin marks from the
# transliterator; drop both and refuse fragments under 3 characters.
clean_candidate_std <- function(x) {
    x <- gsub("[^a-z0-9 ]", "", coalesce(x, ""))
    x <- trimws(gsub("\\s+", " ", x))
    # Ganganagar/Hanumangarh canal villages are named like "26 gb"; keep those
    # verbatim. Everywhere else digits are OCR abbreviation marks
    # (praa0 vi0 = primary school) or glued part numbers; turn them to spaces.
    is_chak <- grepl("^[0-9]+\\s*[a-z]{1,3}($|\\s)", x)
    x <- ifelse(is_chak, x, trimws(gsub("\\s+", " ", gsub("[0-9]+", " ", x))))
    ifelse(is.na(x) | nchar(x) < 3, NA_character_, x)
}

# Consonant skeleton for transliteration-robust exact matching: the libindic
# transliterations double vowels and insert schwa 'a's ("chaakasoo" for
# Chaksu), so vowels carry no signal. Keep the leading character, drop other
# vowels, unify w/v, collapse repeats. Ambiguity from over-merging is handled
# by exact_stage's dedup within block.
skeleton_key <- function(x) {
    x <- tolower(coalesce(x, ""))
    is_chak <- grepl("^[0-9]+\\s*[a-z]{1,3}$", x)
    chak <- gsub("\\s+", "", x)
    x <- gsub("[^a-z]", "", x)
    x <- gsub("w", "v", x)
    x <- gsub("m", "n", x)
    head_chr <- substr(x, 1, 1)
    tail_chr <- gsub("[aeiou]", "", substr(x, 2, nchar(x)))
    s <- paste0(head_chr, tail_chr)
    s <- gsub("(.)\\1+", "\\1", s)
    s <- ifelse(is_chak, chak, s)
    ifelse(nchar(s) < 2, NA_character_, s)
}

clean_candidate_dev <- function(x) {
    x <- sub("^[0-9०-९]+\\s*", "", x)
    x <- trimws(gsub("\\s+", " ", x))
    ifelse(is.na(x) | nchar(x) < 2, NA_character_, x)
}

# Fuzzy-map roll tehsil names (mandal) onto the reference subdistrict
# vocabulary within each mapped district, so tehsil-blocked stages share a
# vocabulary. Returns (lgd_district, mandal_std, subdistrict_ref).
build_tehsil_map <- function(ps_dir, ref_tehsils, threshold = 0.25) {
    roll_tehsils <- ps_dir |>
        filter(!is.na(lgd_district), !is.na(mandal_std), mandal_std != "") |>
        distinct(lgd_district, mandal_std)
    ref_tehsils <- ref_tehsils |>
        filter(!is.na(subdistrict_std), subdistrict_std != "") |>
        distinct(block_key, subdistrict_std)
    m <- match_best_in_block(roll_tehsils$mandal_std, roll_tehsils$lgd_district,
                             ref_tehsils$subdistrict_std, ref_tehsils$block_key,
                             threshold)
    roll_tehsils |>
        mutate(subdistrict_ref = ifelse(is.na(m$cand_idx), NA_character_,
                                        ref_tehsils$subdistrict_std[m$cand_idx]),
               tehsil_match_distance = m$match_distance)
}

# One cascade stage: exact join of a candidate column against a reference,
# blocked on district (and optionally tehsil). `ref` must carry village_key,
# block_key, lgd_gp_code, lgd_gp_name, ref_source. Ambiguous keys (same
# village string mapping to >1 GP within the block) are dropped and counted.
exact_stage <- function(pending, cand_col, ref, stage_name) {
    ref_dedup <- ref |>
        group_by(block_key, village_key) |>
        summarise(
            lgd_gp_code = first(lgd_gp_code),
            lgd_gp_name = first(lgd_gp_name),
            ref_source = first(ref_source),
            n_gp = n_distinct(lgd_gp_code),
            .groups = "drop"
        )
    ambiguous <- ref_dedup |> filter(n_gp > 1)
    ref_dedup <- ref_dedup |> filter(n_gp == 1) |> select(-n_gp)

    hits <- pending |>
        filter(!is.na(.data[[cand_col]])) |>
        inner_join(ref_dedup,
                   by = setNames(c("block_key", "village_key"),
                                 c("block_key", cand_col))) |>
        mutate(match_stage = stage_name, match_distance = 0,
               tie_count = 1L)
    list(hits = hits, n_ambiguous_keys = nrow(ambiguous))
}

# One fuzzy cascade stage over the still-pending parts.
fuzzy_stage <- function(pending, cand_col, ref, stage_name, threshold) {
    ref_dedup <- ref |>
        distinct(block_key, village_key, lgd_gp_code, lgd_gp_name, ref_source)
    q <- pending |> filter(!is.na(.data[[cand_col]]))
    if (nrow(q) == 0) return(q |> mutate(match_stage = character(0)))

    m <- match_best_in_block(q[[cand_col]], q$block_key,
                             ref_dedup$village_key, ref_dedup$block_key,
                             threshold)
    hit_rows <- !is.na(m$cand_idx)
    q[hit_rows, ] |>
        mutate(
            lgd_gp_code = ref_dedup$lgd_gp_code[m$cand_idx[hit_rows]],
            lgd_gp_name = ref_dedup$lgd_gp_name[m$cand_idx[hit_rows]],
            ref_source = ref_dedup$ref_source[m$cand_idx[hit_rows]],
            match_stage = stage_name,
            match_distance = m$match_distance[hit_rows],
            tie_count = m$tie_count[hit_rows]
        )
}

# Run the full cascade for one candidate column set. `stages` is a list of
# lists with fields: name, type ("exact"/"fuzzy"), ref, cand ("dev"/"std"),
# threshold (fuzzy only), block ("district"/"tehsil").
run_cascade <- function(ps_pending, cand_rank, stages) {
    matched <- list()
    ambig_counts <- list()
    for (st in stages) {
        if (nrow(ps_pending) == 0) break
        cand_col <- sprintf("village_cand_%d_%s", cand_rank, st$cand)
        block_col <- if (identical(st$block, "tehsil")) "tehsil_block_key" else "district_block_key"
        ps_stage <- ps_pending |> mutate(block_key = .data[[block_col]])
        if (st$type == "exact") {
            res <- exact_stage(ps_stage, cand_col, st$ref, st$name)
            hits <- res$hits
            ambig_counts[[st$name]] <- res$n_ambiguous_keys
        } else {
            hits <- fuzzy_stage(ps_stage, cand_col, st$ref, st$name, st$threshold)
        }
        if (nrow(hits) > 0) {
            matched[[st$name]] <- hits |> select(-block_key)
            ps_pending <- ps_pending |> filter(!filename %in% hits$filename)
        }
    }
    list(matched = bind_rows(matched), pending = ps_pending,
         ambiguous = ambig_counts)
}

URBAN_PATTERN <- "ward|nagar|municipal|\\bnp\\b|वार्ड|नगर"

flag_urban <- function(ps_dir) {
    ps_dir |>
        mutate(urban_flag = grepl(URBAN_PATTERN,
                                  paste(coalesce(ps_addr_t13n, ""),
                                        coalesce(ps_name_t13n, ""),
                                        coalesce(ps_addr_dev, ""),
                                        coalesce(ps_name_dev, "")),
                                  ignore.case = TRUE, perl = TRUE))
}

bridge_audits <- function(bridge, ps_dir, state, script_prefix) {
    by_district <- ps_dir |>
        left_join(bridge |> select(filename, match_stage),
                  by = "filename") |>
        group_by(district_std) |>
        summarise(
            n_parts = n(),
            n_electors = sum(n_electors),
            n_matched = sum(!is.na(match_stage)),
            share_parts_matched = mean(!is.na(match_stage)),
            electors_matched = sum(n_electors[!is.na(match_stage)]),
            share_electors_matched = electors_matched / n_electors,
            share_rural_electors_matched =
                sum(n_electors[!is.na(match_stage) & !urban_flag]) /
                pmax(sum(n_electors[!urban_flag]), 1),
            .groups = "drop"
        )
    write_audit(by_district, sprintf("%s_%s_ps_match_by_district.csv",
                                     script_prefix, state))

    by_stage <- bridge |>
        count(match_stage, ref_source) |>
        mutate(share = n / sum(n))
    write_audit(by_stage, sprintf("%s_%s_ps_match_by_stage.csv",
                                  script_prefix, state))

    set.seed(42)
    unmatched_pool <- ps_dir |>
        anti_join(bridge, by = "filename") |>
        filter(!urban_flag) |>
        select(district_std, filename, ps_name_t13n, main_town_t13n,
               village_cand_1_std, village_cand_2_std)
    unmatched <- unmatched_pool |>
        slice_sample(n = min(2000, nrow(unmatched_pool)))
    write_audit(unmatched, sprintf("%s_%s_ps_unmatched_sample.csv",
                                   script_prefix, state))
    by_district
}
