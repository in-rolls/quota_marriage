# 03c_ps_gp_match_up.R
# UP polling-part -> LGD GP bridge. Same cascade as Rajasthan minus the
# delimitation reference (UP has none): t13n exact -> fuzzy within district ->
# fuzzy within tehsil, all against the LGD 2024 village -> GP mapping.

library(here)
library(dplyr)
library(tidyr)
library(readr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "03_bridge_helpers.R"))

ps_dir <- arrow::read_parquet(here("data", "bridge", "ps_directory_up.parquet")) |>
    flag_urban()

ref2 <- read_csv(here("data", "external", "quota_raj", "up_village_gp_mapping_2024.csv"),
                 show_col_types = FALSE) |>
    filter(!is.na(`Local Body Code`)) |>
    transmute(
        block_key = normalize_string(`District Name`),
        subdistrict_std = normalize_string(`Subdistrict Name`),
        tehsil_key = paste(normalize_string(`District Name`),
                           normalize_string(`Subdistrict Name`), sep = "|"),
        village_key = normalize_string(`Village Name`),
        lgd_gp_code = `Local Body Code`,
        lgd_gp_name = `Local Body Name`,
        ref_source = "lgd2024"
    ) |>
    filter(!is.na(village_key), village_key != "")

ps_dir <- ps_dir |> mutate(district_dev_clean = clean_district_dev(district_dev))

district_map <- build_district_map_dev(
    ps_dir$district_dev_clean,
    ref2$block_key,
    here("data-raw", "up_district_xwalk_rolls.csv")
)
write_audit(district_map, "03c_up_district_map.csv")
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

tehsil_map <- build_tehsil_map(ps_dir, ref2)
write_audit(tehsil_map, "03c_up_tehsil_map.csv")
ps_dir <- ps_dir |>
    left_join(tehsil_map |> select(lgd_district, mandal_std, subdistrict_ref),
              by = c("lgd_district", "mandal_std")) |>
    mutate(tehsil_block_key = ifelse(is.na(subdistrict_ref), NA_character_,
                                     paste(lgd_district, subdistrict_ref, sep = "|")))

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
    list(name = "t13n_exact_lgd_tehsil", type = "exact", cand = "std",
         ref = ref2_tehsil, block = "tehsil"),
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

arrow::write_parquet(bridge, here("data", "bridge", "ps_gp_xwalk_up.parquet"))

bridge_audits(bridge, ps_dir, "up", "03c")

message(sprintf(
    "03c complete: %d of %d parts matched (%.1f%% of rural electors)",
    nrow(bridge), nrow(ps_dir),
    100 * sum(bridge$n_electors[!bridge$urban_flag]) /
        sum(ps_dir$n_electors[!ps_dir$urban_flag])))
