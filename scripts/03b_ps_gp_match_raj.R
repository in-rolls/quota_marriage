# 03b_ps_gp_match_raj.R
# Rajasthan polling-part -> LGD GP bridge.
# Reference R1: the 2014 delimitation village->GP table (Devanagari, vintage-
# matched to the rolls), mapped to LGD GP codes via block-level name matching.
# Reference R2: the LGD 2024 village->GP mapping (transliterated names only).
# Cascade per candidate village string: Devanagari exact (R1) -> t13n exact
# (R1, R2) -> fuzzy within district (R1+R2) -> fuzzy within tehsil (R2).

library(here)
library(dplyr)
library(tidyr)
library(readr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "03_bridge_helpers.R"))

ps_dir <- arrow::read_parquet(here("data", "bridge", "ps_directory_raj.parquet")) |>
    flag_urban()

lgd_gp <- read_csv(source_path("raj_lgd_directory"),
                   show_col_types = FALSE) |>
    mutate(
        gp_name_std = normalize_string(gp_name),
        block_name_std = normalize_string(block_name),
        zila_name_std = normalize_string(zila_name)
    )

# =============================================================================
# District mapping: roll districts -> LGD zila names
# =============================================================================

ps_dir <- ps_dir |> mutate(district_dev_clean = clean_district_dev(district_dev))

district_map <- build_district_map_dev(
    ps_dir$district_dev_clean,
    lgd_gp$zila_name_std,
    here("data-raw", "raj_district_xwalk_rolls.csv")
)
write_audit(district_map, "03b_raj_district_map.csv")
if (any(is.na(district_map$ref_district))) {
    warning("Unmapped roll districts: ",
            paste(district_map$translit[is.na(district_map$ref_district)],
                  collapse = ", "))
}

ps_dir <- ps_dir |>
    left_join(district_map |> select(district_dev_clean, lgd_district = ref_district),
              by = "district_dev_clean") |>
    mutate(
        district_block_key = lgd_district,
        tehsil_block_key = paste(lgd_district, mandal_std, sep = "|")
    )

# =============================================================================
# Reference R1: delim 2014 villages -> GP -> LGD GP code
# =============================================================================

delim <- read_csv(source_path("delim_2014"),
                  show_col_types = FALSE) |>
    mutate(
        district_std = normalize_string(district),
        gp_std = normalize_string(gp_goog_translate),
        samiti_std = normalize_string(ps_goog_translate),
        village_dev = normalize_devanagari(coalesce(
            na_if(old_gp_village_fixed, ""), old_gp_villages)),
        village_std = normalize_string(gp_village_goog_translate)
    ) |>
    mutate(across(c(village_dev, village_std), ~ na_if(.x, ""))) |>
    filter(!is.na(village_dev) | !is.na(village_std))

# The delim file is the 2014 *delimitation*: it covers only the ~1,500 GPs
# created/changed in 2014, so it supplements rather than replaces the LGD
# reference. Its district spellings differ from LGD zila names in a few cases.
delim_district_map <- build_district_map(
    delim$district_std,
    lgd_gp$zila_name_std,
    here("data-raw", "raj_delim_district_xwalk.csv")
)
write_audit(delim_district_map, "03b_raj_delim_district_map.csv")
delim <- delim |>
    left_join(delim_district_map |>
                  select(roll_district, lgd_zila = ref_district),
              by = c("district_std" = "roll_district")) |>
    mutate(district_std = coalesce(lgd_zila, district_std)) |>
    select(-lgd_zila)

# GP-level table for LGD matching (one row per district x samiti x GP)
delim_gps <- delim |>
    distinct(district_std, samiti_std, gp_std, current_gp_name)

# Match delim samiti -> LGD block within district (exact then fuzzy)
delim_blocks <- delim_gps |> distinct(district_std, samiti_std)
lgd_blocks <- lgd_gp |> distinct(zila_name_std, block_name_std, block_code)

block_exact <- delim_blocks |>
    inner_join(lgd_blocks, by = c("district_std" = "zila_name_std",
                                  "samiti_std" = "block_name_std")) |>
    mutate(block_match = "exact")

block_pending <- delim_blocks |> anti_join(block_exact,
                                           by = c("district_std", "samiti_std"))
bm <- match_best_in_block(block_pending$samiti_std, block_pending$district_std,
                          lgd_blocks$block_name_std, lgd_blocks$zila_name_std,
                          threshold = 0.25)
block_fuzzy <- block_pending[!is.na(bm$cand_idx), ] |>
    mutate(block_code = lgd_blocks$block_code[bm$cand_idx[!is.na(bm$cand_idx)]],
           block_match = "fuzzy")

delim_block_map <- bind_rows(
    block_exact |> select(district_std, samiti_std, block_code, block_match),
    block_fuzzy |> select(district_std, samiti_std, block_code, block_match)
)
write_audit(delim_block_map |> count(block_match),
            "03b_raj_delim_block_match.csv")

# Match delim GP -> LGD GP within block (exact then fuzzy), fallback district
delim_gps <- delim_gps |>
    left_join(delim_block_map, by = c("district_std", "samiti_std"))

gp_exact <- delim_gps |>
    filter(!is.na(block_code)) |>
    inner_join(lgd_gp |> select(block_code, gp_name_std, gp_code, gp_name),
               by = c("block_code", "gp_std" = "gp_name_std")) |>
    mutate(gp_match = "exact_block")

gp_pending <- delim_gps |> anti_join(gp_exact, by = c("district_std", "samiti_std", "gp_std"))
gp_pending_blocked <- gp_pending |> filter(!is.na(block_code))
gm <- match_best_in_block(gp_pending_blocked$gp_std,
                          as.character(gp_pending_blocked$block_code),
                          lgd_gp$gp_name_std, as.character(lgd_gp$block_code),
                          threshold = 0.20)
gp_fuzzy <- gp_pending_blocked[!is.na(gm$cand_idx), ] |>
    mutate(gp_code = lgd_gp$gp_code[gm$cand_idx[!is.na(gm$cand_idx)]],
           gp_name = lgd_gp$gp_name[gm$cand_idx[!is.na(gm$cand_idx)]],
           gp_match = "fuzzy_block")

gp_pending2 <- gp_pending |>
    anti_join(gp_fuzzy, by = c("district_std", "samiti_std", "gp_std"))
gm2 <- match_best_in_block(gp_pending2$gp_std, gp_pending2$district_std,
                           lgd_gp$gp_name_std, lgd_gp$zila_name_std,
                           threshold = 0.15)
gp_fuzzy_dist <- gp_pending2[!is.na(gm2$cand_idx), ] |>
    mutate(gp_code = lgd_gp$gp_code[gm2$cand_idx[!is.na(gm2$cand_idx)]],
           gp_name = lgd_gp$gp_name[gm2$cand_idx[!is.na(gm2$cand_idx)]],
           gp_match = "fuzzy_district")

delim_gp_map <- bind_rows(gp_exact, gp_fuzzy, gp_fuzzy_dist) |>
    select(district_std, samiti_std, gp_std, gp_code, gp_name, gp_match)

write_audit(delim_gp_map |> count(gp_match) |>
                mutate(total_delim_gps = nrow(delim_gps)),
            "03b_raj_delim_gp_lgd_match.csv")

ref1 <- delim |>
    inner_join(delim_gp_map, by = c("district_std", "samiti_std", "gp_std")) |>
    transmute(
        block_key = district_std,
        village_key_dev = village_dev,
        village_key_std = village_std,
        lgd_gp_code = gp_code,
        lgd_gp_name = gp_name,
        ref_source = "delim2014"
    )

# =============================================================================
# Reference R2: LGD 2024 village -> GP mapping
# =============================================================================

ref2 <- read_csv(source_path("raj_village_mapping"),
                 show_col_types = FALSE) |>
    filter(!is.na(`Local Body Code`)) |>
    transmute(
        district_raw = normalize_string(`District Name`),
        subdistrict_std = normalize_string(`Subdistrict Name`),
        village_key = normalize_string(`Village Name`),
        lgd_gp_code = `Local Body Code`,
        lgd_gp_name = `Local Body Name`,
        ref_source = "lgd2024"
    ) |>
    filter(!is.na(village_key), village_key != "")

# Remap this file's district spellings into the LGD zila space used by the
# polling-part directory, so exact joins share one district vocabulary
ref2_district_map <- build_district_map(
    ref2$district_raw,
    lgd_gp$zila_name_std,
    here("data-raw", "raj_lgd2024_district_xwalk.csv")
)
write_audit(ref2_district_map, "03b_raj_lgd2024_district_map.csv")
ref2 <- ref2 |>
    left_join(ref2_district_map |>
                  select(roll_district, lgd_zila = ref_district),
              by = c("district_raw" = "roll_district")) |>
    mutate(
        block_key = coalesce(lgd_zila, district_raw),
        tehsil_key = paste(block_key, subdistrict_std, sep = "|")
    ) |>
    select(-district_raw, -lgd_zila)

# Map roll tehsils (mandal) into this file's subdistrict vocabulary so the
# tehsil-blocked stages can join exactly
tehsil_map <- build_tehsil_map(ps_dir, ref2)
write_audit(tehsil_map, "03b_raj_tehsil_map.csv")
ps_dir <- ps_dir |>
    left_join(tehsil_map |> select(lgd_district, mandal_std, subdistrict_ref),
              by = c("lgd_district", "mandal_std")) |>
    mutate(tehsil_block_key = ifelse(is.na(subdistrict_ref), NA_character_,
                                     paste(lgd_district, subdistrict_ref, sep = "|")))

# =============================================================================
# Cascade
# =============================================================================

ref1_dev <- ref1 |> rename(village_key = village_key_dev) |>
    filter(!is.na(village_key))
ref1_std <- ref1 |> rename(village_key = village_key_std) |>
    filter(!is.na(village_key))
ref2_tehsil <- ref2 |> mutate(block_key = tehsil_key)
ref2_skel <- ref2 |> mutate(village_key = skeleton_key(village_key)) |>
    filter(!is.na(village_key))
ref2_skel_tehsil <- ref2_skel |> mutate(block_key = tehsil_key)

ps_dir <- ps_dir |>
    mutate(
        village_cand_1_skel = skeleton_key(village_cand_1_std),
        village_cand_2_skel = skeleton_key(village_cand_2_std),
        village_cand_3_skel = skeleton_key(village_cand_3_std),
        village_cand_4_skel = skeleton_key(village_cand_4_std)
    )

stages <- list(
    list(name = "dev_exact_delim", type = "exact", cand = "dev",
         ref = ref1_dev, block = "district"),
    list(name = "t13n_exact_lgd_tehsil", type = "exact", cand = "std",
         ref = ref2_tehsil, block = "tehsil"),
    list(name = "t13n_exact_delim", type = "exact", cand = "std",
         ref = ref1_std, block = "district"),
    list(name = "t13n_exact_lgd", type = "exact", cand = "std",
         ref = ref2, block = "district"),
    list(name = "skel_exact_lgd_tehsil", type = "exact", cand = "skel",
         ref = ref2_skel_tehsil, block = "tehsil"),
    list(name = "skel_exact_lgd", type = "exact", cand = "skel",
         ref = ref2_skel, block = "district"),
    list(name = "skel_fuzzy_lgd_tehsil", type = "fuzzy", cand = "skel",
         ref = ref2_skel_tehsil, threshold = 0.12, block = "tehsil"),
    list(name = "fuzzy_tehsil_lgd", type = "fuzzy", cand = "std",
         ref = ref2_tehsil, threshold = JW_VILLAGE_TEHSIL, block = "tehsil"),
    list(name = "fuzzy_district_delim", type = "fuzzy", cand = "std",
         ref = ref1_std, threshold = JW_VILLAGE_DISTRICT, block = "district"),
    list(name = "fuzzy_district_lgd", type = "fuzzy", cand = "std",
         ref = ref2, threshold = JW_VILLAGE_DISTRICT, block = "district")
)

pending <- ps_dir |> filter(!is.na(lgd_district))
all_matched <- list()
for (cand_rank in 1:4) {
    res <- run_cascade(pending, cand_rank, stages)
    if (nrow(res$matched) > 0) {
        all_matched[[cand_rank]] <- res$matched |> mutate(cand_rank = cand_rank)
    }
    pending <- res$pending
}

bridge <- bind_rows(all_matched) |>
    select(state, district_std, lgd_district, filename, n_electors, urban_flag,
           lgd_gp_code, lgd_gp_name, ref_source, match_stage, match_distance,
           tie_count, cand_rank)

arrow::write_parquet(bridge, here("data", "bridge", "ps_gp_xwalk_raj.parquet"))

# =============================================================================
# Audits
# =============================================================================

by_district <- bridge_audits(bridge, ps_dir, "raj", "03b")

# Cross-source disagreement: parts whose Devanagari-exact delim match and
# t13n-exact LGD match give different GPs
dev_hits <- exact_stage(
    ps_dir |> filter(!is.na(lgd_district)) |>
        mutate(block_key = district_block_key),
    "village_cand_1_dev",
    ref1 |> rename(village_key = village_key_dev) |> filter(!is.na(village_key)),
    "dev")$hits |> select(filename, gp_delim = lgd_gp_code)
lgd_hits <- exact_stage(
    ps_dir |> filter(!is.na(lgd_district)) |>
        mutate(block_key = district_block_key),
    "village_cand_1_std", ref2, "lgd")$hits |>
    select(filename, gp_lgd = lgd_gp_code)
disagreements <- dev_hits |>
    inner_join(lgd_hits, by = "filename") |>
    summarise(n_both = n(), n_disagree = sum(gp_delim != gp_lgd),
              share_disagree = n_disagree / n_both)
write_audit(disagreements, "03b_raj_source_disagreements.csv")

message(sprintf(
    "03b complete: %d of %d parts matched (%.1f%% of rural electors)",
    nrow(bridge), nrow(ps_dir),
    100 * sum(bridge$n_electors[!bridge$urban_flag]) /
        sum(ps_dir$n_electors[!ps_dir$urban_flag])))
