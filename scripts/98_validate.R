library(testthat)
library(dplyr)
source("scripts/00_sources.R")
test_that("source manifest rejects unknown files and corrupted cache entries", {
  expect_error(source_path("unlisted"), "Unpinned source")
  cache <- withr::local_tempdir()
  withr::local_envvar(c(INDIA_DATA_HOME = cache))
  spec <- jsonlite::read_json("data/sources.json")$raj_lgd_directory
  path <- file.path(cache, spec$provider, spec$ref, spec$path)
  dir.create(dirname(path), recursive = TRUE)
  writeLines("damaged", path)
  expect_error(source_path("raj_lgd_directory"), "Cached source checksum mismatch")
})
test_that("canonical treatment panels preserve source anchors and reservation assignments", {
  for (state in c("raj", "up")) {
    for (four_cycle in c(FALSE, TRUE)) {
      waves <- if (four_cycle) {
        if (state == "raj") c(2005, 2010, 2015, 2020) else c(2005, 2010, 2015, 2021)
      } else {
        c(2005, 2010)
      }
      raw <- arrow::read_parquet(source_path(paste0(state, "_panel_", paste(waves, collapse = "_"))))
      actual <- treatment_panel(state, four_cycle)
      if (state == "up") raw <- raw |> filter(if_all(all_of(paste0("women_reserved_", waves)), ~ !is.na(.x)))
      expect_equal(nrow(actual), nrow(raw))
      if (state == "up") {
        expect_identical(actual$key_2010, raw$key_2010)
        for (wave in waves) expect_equal(actual[[paste0("treat_", wave)]], as.integer(raw[[paste0("women_reserved_", wave)]]))
      } else {
        expect_identical(actual$match_key, raw$match_key)
        for (wave in waves) expect_identical(actual[[paste0("treat_", wave)]], raw[[paste0("treat_", wave)]])
      }
    }
  }
})

source("scripts/receiving_helpers.R")
test_that("receiving aggregates conserve male records and distinguish missing spouse ages", {
  for (state in c("raj", "up")) {
    cells <- arrow::read_parquet(paste0("data/cohorts/receiving_", state, ".parquet"))
    check <- readr::read_csv(paste0("data/audit/receiving_", state, "_join_checks.csv"), show_col_types = FALSE)
    expect_gt(nrow(cells), 0)
    expect_false(anyDuplicated(cells[c("lgd_gp_code", "birth_year")]) > 0)
    expect_equal(sum(cells$n_men), check$n_men)
    expect_equal(sum(cells$n_linked), check$n_distinct_linked)
    expect_true(all(cells$n_linked <= cells$n_men))
    expect_true(all(cells$n_gap <= cells$n_linked))
    expect_true(all(is.na(cells$mean_gap[cells$n_gap == 0])))
    expect_equal(cells$linked_wife_share, cells$n_linked / cells$n_men)
    expect_equal(cells$dose_main, childhood_dose(
      cells$birth_year, cells,
      if (state == "raj") {
        list(`2005` = c(2005, 2010), `2010` = c(2010, 2015), `2015` = c(2015, 2020))
      } else {
        list(`2005` = c(2005, 2010), `2010` = c(2010, 2015), `2015` = c(2015, 2021))
      }
    ))
  }
})
test_that("primary inference has eight tests and independently reproducible coefficients", {
  results <- readr::read_csv("data/audit/receiving_estimates.csv", show_col_types = FALSE) |>
    filter(variant == "primary")
  expect_equal(nrow(results), 8)
  expect_equal(results$holm_boot_p, p.adjust(results$boot_p, "holm"))
  expect_true(all(results$boot_draws == 9999))
  for (i in seq_len(nrow(results))) {
    r <- results[i, ]
    id <- paste(r$state, r$wave, "primary", r$outcome, sep = "_")
    saved <- readRDS(paste0("data/models/", id, ".rds"))
    d <- saved$data
    expect_equal(as.numeric(tapply(d$w, d$lgd_gp_code, sum)), rep(1, r$n_gps))
    transformed <- bootstrap_model(d, r$wave)
    x <- model.matrix(transformed$model)
    y <- transformed$data$y
    beta <- solve(crossprod(x), crossprod(x, y))
    expect_equal(unname(beta["treatment", 1]), r$estimate, tolerance = 1e-9)
    e <- as.numeric(y - x %*% beta)
    scores <- rowsum(x * e, transformed$data$block)
    bread <- solve(crossprod(x))
    raw_v <- bread %*% crossprod(scores) %*% bread
    n <- nrow(x)
    g <- n_distinct(d$block)
    k <- attr(vcov(saved$model, attr = TRUE), "df.K")
    v <- raw_v * (n - 1) / (n - k) * g / (g - 1)
    expect_equal(sqrt(v["treatment", "treatment"]), r$se, tolerance = 1e-8)
    expect_equal(saved$bootstrap$N, nrow(d))
  }
})
