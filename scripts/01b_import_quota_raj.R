# 01b_import_quota_raj.R
# Snapshot the quota_raj and delim_raj inputs into data/external/ with a
# provenance manifest, and assert vendored utility functions have not drifted.

library(here)
library(dplyr)
library(purrr)
library(digest)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

SNAPSHOT_FILES <- tribble(
    ~repo,        ~rel_path,                                        ~dest_dir,
    "quota_raj",  "data/raj/shrug_gp_raj_05_10_block.parquet",      "quota_raj",
    "quota_raj",  "data/up/shrug_gp_up_05_10_block.parquet",        "quota_raj",
    "quota_raj",  "data/raj/shrug_gp_raj_05_20_block.parquet",      "quota_raj",
    "quota_raj",  "data/raj/raj_05_20.parquet",                     "quota_raj",
    "quota_raj",  "data/raj/raj_05_10.parquet",                     "quota_raj",
    "quota_raj",  "data/raj/raj_10_15.parquet",                     "quota_raj",
    "quota_raj",  "data/up/up_05_21.parquet",                       "quota_raj",
    "quota_raj",  "data/up/shrug_gp_up_05_21_block.parquet",        "quota_raj",
    "quota_raj",  "data/lgd/raj_village_gp_mapping_2024.csv",       "quota_raj",
    "quota_raj",  "data/lgd/up_village_gp_mapping_2024.csv",        "quota_raj",
    "quota_raj",  "data/lgd/processed/lgd_raj_block_gp.csv",        "quota_raj",
    "quota_raj",  "data/lgd/processed/lgd_up_block_gp.csv",         "quota_raj",
    "quota_raj",  "data/crosswalks/active/raj_district_xwalk.csv",  "quota_raj",
    "delim_raj",  "data/gp_2014_delim_processed.csv",               "delim_raj",
    "delim_raj",  "data/gp_2019_delim_processed.csv",               "delim_raj"
)

repo_dirs <- c(quota_raj = QUOTA_RAJ_DIR, delim_raj = DELIM_RAJ_DIR)

repo_heads <- map_chr(repo_dirs, function(d) {
    out <- suppressWarnings(system2("git", c("-C", d, "rev-parse", "HEAD"),
                                    stdout = TRUE, stderr = FALSE))
    if (length(out) == 0) NA_character_ else out[1]
})

manifest <- SNAPSHOT_FILES |>
    mutate(
        source_path = file.path(repo_dirs[repo], rel_path),
        dest_path = here("data", "external", dest_dir, basename(rel_path))
    )

missing <- manifest |> filter(!file.exists(source_path))
if (nrow(missing) > 0) {
    stop("Missing source files:\n", paste(missing$source_path, collapse = "\n"))
}

for (d in unique(dirname(manifest$dest_path))) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

copied <- pmap_lgl(manifest |> select(source_path, dest_path),
                   function(source_path, dest_path) {
    if (file.exists(dest_path) &&
        digest(file = dest_path) == digest(file = source_path)) {
        return(FALSE)
    }
    file.copy(source_path, dest_path, overwrite = TRUE)
})

manifest_out <- manifest |>
    mutate(
        copied_this_run = copied,
        md5 = map_chr(dest_path, ~ digest(file = .x)),
        bytes = file.size(dest_path),
        source_mtime = as.character(file.mtime(source_path)),
        repo_head = repo_heads[repo]
    ) |>
    select(repo, rel_path, md5, bytes, source_mtime, repo_head, copied_this_run)

write_audit(manifest_out, "01b_import_manifest.csv")

# =============================================================================
# Vendored-function drift check against quota_raj @ HEAD
# =============================================================================

VENDOR_SOURCES <- list(
    "scripts/00_utils.R" = c("make_match_key", "normalize_string",
                             "normalize_string_strict", "fuzzy_match_within_block",
                             "run_t_tests", "convert_sci_to_decimal",
                             "aggressive_round", "format_coef_stars",
                             "format_se_parens", "format_n_comma"),
    "scripts/05b_short_term_random_rotation.R" = c("compute_district_chisq")
)

extract_function_body <- function(lines, fn_name) {
    start <- grep(paste0("^", fn_name, " <- function"), lines)
    if (length(start) == 0) return(NA_character_)
    depth <- 0
    for (i in start[1]:length(lines)) {
        depth <- depth + lengths(regmatches(lines[i], gregexpr("\\{", lines[i]))) -
                 lengths(regmatches(lines[i], gregexpr("\\}", lines[i])))
        if (depth == 0 && i > start[1]) {
            return(paste(gsub("\\s+", " ", trimws(lines[start[1]:i])), collapse = " "))
        }
    }
    NA_character_
}

local_lines <- readLines(here("scripts", "00_utils.R"))

drift <- imap_dfr(VENDOR_SOURCES, function(fns, src_file) {
    src_lines <- readLines(file.path(QUOTA_RAJ_DIR, src_file))
    map_dfr(fns, function(fn) {
        tibble(
            source_file = src_file,
            fn = fn,
            identical = identical(extract_function_body(src_lines, fn),
                                  extract_function_body(local_lines, fn))
        )
    })
})

write_audit(drift, "01b_vendored_function_drift.csv")
if (!all(drift$identical)) {
    warning("Vendored functions have drifted from quota_raj: ",
            paste(drift$fn[!drift$identical], collapse = ", "))
}

message("01b complete")
