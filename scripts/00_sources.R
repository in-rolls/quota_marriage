source_path <- function(name) {
    spec <- jsonlite::read_json(here::here("data", "sources.json"))[[name]]
    if (is.null(spec)) stop("Unpinned source: ", name)
    cache <- path.expand(Sys.getenv("INDIA_DATA_HOME", unset = "~/data"))
    path <- file.path(cache, spec$provider, spec$ref, spec$path)
    if (!file.exists(path)) {
        dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
        temporary <- tempfile(tmpdir = dirname(path))
        on.exit(unlink(temporary), add = TRUE)
        sibling <- here::here("..", spec$provider, spec$path)
        if (file.exists(sibling) && identical(
            digest::digest(sibling, algo = "sha256", file = TRUE), spec$sha256
        )) {
            if (!file.copy(sibling, temporary)) stop("Cannot cache ", sibling)
        } else {
            url <- spec$url
            if (is.null(url)) url <- paste(
                "https://raw.githubusercontent.com/in-rolls",
                spec$provider, spec$ref, spec$path, sep = "/"
            )
            utils::download.file(url, temporary, mode = "wb", quiet = TRUE)
        }
        if (!identical(digest::digest(temporary, algo = "sha256", file = TRUE), spec$sha256)) {
            stop("Source checksum mismatch: ", name)
        }
        if (!file.rename(temporary, path)) stop("Cannot save verified source: ", path)
    }
    if (!identical(digest::digest(path, algo = "sha256", file = TRUE), spec$sha256)) {
        stop("Cached source checksum mismatch: ", name)
    }
    path
}

treatment_panel <- function(state, four_cycle = FALSE) {
    waves <- if (four_cycle) {
        if (state == "raj") c(2005, 2010, 2015, 2020) else c(2005, 2010, 2015, 2021)
    } else c(2005, 2010)
    panel_name <- paste(waves, collapse = "_")
    panel <- arrow::read_parquet(source_path(paste0(state, "_panel_", panel_name)))
    geography <- arrow::read_parquet(source_path(paste0(state, "_lgd_bridge")))
    if (state == "raj") {
        panel <- dplyr::left_join(panel, geography, by = "match_key", relationship = "many-to-one")
    } else {
        panel <- panel |>
            dplyr::filter(dplyr::if_all(dplyr::all_of(paste0("women_reserved_", waves)), ~ !is.na(.x)))
        for (year in waves) {
            panel <- panel |> dplyr::mutate(
                !!paste0("treat_", year) := as.integer(.data[[paste0("women_reserved_", year)]]),
                !!paste0("obc_", year) := as.integer(.data[[paste0("reservation_class_", year)]] == "obc"),
                !!paste0("dalit_", year) := as.integer(.data[[paste0("reservation_class_", year)]] %in% c("sc", "st"))
            )
        }
        panel <- panel |> dplyr::mutate(
            district_name_eng_2010 = dplyr::recode(district_name_eng_2010, "Ramabai Nagar" = "Kanpur Dehat"),
            dist_block_2010 = paste(district_name_eng_2010, block_name_eng_2010, sep = "_")
        )
        if (four_cycle) panel <- panel |> dplyr::mutate(count_treated = treat_2005 + treat_2010 + treat_2015)
        geography <- geography |>
            dplyr::filter(.data$panel == .env$panel_name) |>
            dplyr::select(anchor_key, dplyr::starts_with("lgd_"), block_match_type,
                          gp_match_type, match_distance, match_confidence)
        panel <- dplyr::left_join(panel, geography, by = c("key_2010" = "anchor_key"), relationship = "one-to-one")
    }
    covariates <- arrow::read_parquet(source_path(paste0(state, "_census"))) |>
        dplyr::filter(!is.na(lgd_gp_code)) |>
        dplyr::select(lgd_gp_code, dplyr::starts_with("pc01_")) |>
        dplyr::distinct()
    stopifnot(!anyDuplicated(covariates$lgd_gp_code))
    dplyr::left_join(panel, covariates, by = "lgd_gp_code", relationship = "many-to-one")
}
