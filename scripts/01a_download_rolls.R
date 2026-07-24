# 01a_download_rolls.R
# Download parsed electoral rolls from Harvard Dataverse (doi:10.7910/DVN/MUEGDT)
# and reassemble the UP multi-part archive.
# Files are public; DATAVERSE_KEY is used if set (helps with rate limits).

library(here)
library(httr2)
library(dplyr)
library(purrr)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

raw_dir <- here("data", "raw")

token <- Sys.getenv("DATAVERSE_KEY", unset = Sys.getenv("DATAVERSE_API_TOKEN"))

# =============================================================================
# List dataset files via the native API
# =============================================================================

req <- request(sprintf("https://%s/api/datasets/:persistentId/versions/:latest/files",
                       DATAVERSE_SERVER)) |>
    req_url_query(persistentId = ROLL_DOI)
if (nzchar(token)) req <- req |> req_headers(`X-Dataverse-key` = token)

resp <- req |> req_retry(max_tries = 5) |> req_perform() |> resp_body_json()
stopifnot(resp$status == "OK")

file_index <- map_dfr(resp$data, function(f) {
    tibble(
        label = f$label,
        id = f$dataFile$id,
        bytes_expected = f$dataFile$filesize,
        md5_expected = f$dataFile$md5 %||% NA_character_
    )
})

targets <- file_index |> filter(label %in% unlist(ROLL_FILES))

missing_targets <- setdiff(unlist(ROLL_FILES), targets$label)
if (length(missing_targets) > 0) {
    stop("Files not found in dataset: ", paste(missing_targets, collapse = ", "))
}

# Raw files are deleted after ingest to save disk; do not re-download a
# state whose rolls are already in parquet
ingested <- c(
    raj = file.exists(here("data", "rolls", "raj", ".ingest_complete")),
    up  = file.exists(here("data", "rolls", "up", ".ingest_complete"))
)
targets <- targets |>
    filter(!(label %in% ROLL_FILES$raj & ingested[["raj"]]),
           !(label %in% ROLL_FILES$up & ingested[["up"]]))

# The UP part files are redundant once the assembled archive exists
up_target_pre <- file.path(raw_dir, "up_all_clean+t13n.csv.gz")
up_expected_pre <- sum(file_index$bytes_expected[file_index$label %in% ROLL_FILES$up])
if (file.exists(up_target_pre) && file.size(up_target_pre) == up_expected_pre) {
    targets <- targets |> filter(!label %in% ROLL_FILES$up)
}

# =============================================================================
# Download with skip-if-complete
# =============================================================================

download_one <- function(label, id, bytes_expected) {
    dest <- file.path(raw_dir, label)
    if (file.exists(dest) && file.size(dest) == bytes_expected) {
        message("Already complete, skipping: ", label)
        return(invisible(dest))
    }
    message(sprintf("Downloading %s (%.1f MB)", label, bytes_expected / 1e6))
    h <- curl::new_handle(low_speed_limit = 1000, low_speed_time = 120)
    if (nzchar(token)) curl::handle_setheaders(h, "X-Dataverse-key" = token)
    url <- sprintf("https://%s/api/access/datafile/%s?format=original",
                   DATAVERSE_SERVER, id)
    tmp <- paste0(dest, ".part")
    curl::curl_download(url, tmp, handle = h, quiet = TRUE, mode = "wb")
    if (file.size(tmp) != bytes_expected) {
        stop(sprintf("Size mismatch for %s: expected %s got %s",
                     label, bytes_expected, file.size(tmp)))
    }
    file.rename(tmp, dest)
    invisible(dest)
}

pwalk(targets |> select(label, id, bytes_expected), download_one)

# =============================================================================
# Reassemble UP parts into a single csv.gz
# =============================================================================

up_target <- file.path(raw_dir, "up_all_clean+t13n.csv.gz")
up_parts <- file.path(raw_dir, ROLL_FILES$up)
up_expected <- up_expected_pre

if (ingested[["up"]]) {
    message("UP already ingested, skipping assembly")
} else if (!file.exists(up_target) || file.size(up_target) != up_expected) {
    message("Concatenating UP parts")
    if (file.exists(up_target)) file.remove(up_target)
    ok <- file.append(up_target, up_parts)
    stopifnot(all(ok))
    stopifnot(file.size(up_target) == up_expected)
} else {
    message("UP archive already assembled, skipping")
}

# =============================================================================
# Integrity: gz readability + header check
# =============================================================================

check_header <- function(path) {
    con <- gzfile(path, "r")
    on.exit(close(con))
    header <- readLines(con, n = 1)
    cols <- strsplit(header, ",")[[1]]
    tibble(
        file = basename(path),
        n_header_cols = length(cols),
        has_elector_name = "elector_name" %in% cols,
        has_relationship = "relationship" %in% cols,
        has_part_no = "part_no" %in% cols
    )
}

check_paths <- Filter(file.exists, c(file.path(raw_dir, ROLL_FILES$raj), up_target))
header_checks <- map_dfr(check_paths, check_header)
if (nrow(header_checks) > 0) {
    stopifnot(all(header_checks$has_elector_name),
              all(header_checks$has_relationship),
              all(header_checks$has_part_no))
}

manifest <- targets |>
    mutate(
        bytes_actual = file.size(file.path(raw_dir, label)),
        complete = bytes_actual == bytes_expected
    )
write_audit(manifest, "01a_download_manifest.csv")
write_audit(header_checks, "01a_header_checks.csv")

message("01a complete")
