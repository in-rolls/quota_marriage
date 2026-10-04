library(testthat)
library(dplyr)
source("scripts/receiving_helpers.R")

test_that("all eligible men form denominators; contested husbands count once", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  men <- data.frame(
    elector_uid = c("a", "b", "c", "d"),
    lgd_gp_code = c(1, 1, 1, 2), age = c(25, 25, 25, 26),
    birth_year = c(1993, 1993, 1993, 1992)
  )
  links <- data.frame(
    husband_uid = c("a", "a", "c"),
    gap = c(3, 4, -2), wife_age = c(22, 21, 27),
    native_exact = c(TRUE, FALSE, FALSE)
  )
  DBI::dbWriteTable(con, "men", men)
  DBI::dbWriteTable(con, "links", links)
  cells <- aggregate_male_cells(con)
  expect_equal(cells$n_men, c(3, 1))
  expect_equal(cells$n_linked, c(2, 0))
  expect_equal(cells$linked_wife_share, c(2 / 3, 0))
  expect_equal(cells$n_contested, c(1, 0))
  expect_equal(cells$n_gap, c(1, 0))
  expect_equal(cells$mean_gap, c(-2, NA))
  expect_equal(cells$n_linked_exact, c(1, 0))
  expect_true(all(is.na(cells$mean_gap_exact)))
})

test_that("exposure uses the man's cohort and missing assignment is not zero", {
  cycles <- list(`2005` = c(2005, 2010), `2010` = c(2010, 2015), `2015` = c(2015, 2020))
  assignments <- data.frame(
    treat_2005 = c(1, 1, 1), treat_2010 = c(1, 1, 1),
    treat_2015 = c(NA, NA, NA)
  )
  expect_equal(childhood_dose(c(1985, 1990, 2000), assignments, cycles), c(0, .2, NA))
  expect_false(identical(
    childhood_dose(1990, assignments[1, ], cycles),
    childhood_dose(1995, assignments[1, ], cycles)
  ))
})

test_that("post-filter GP weights sum to one and 2005 ignores future strata", {
  d <- data.frame(
    lgd_gp_code = c(1, 1, 2, 2), age = c(25, 26, 25, 26),
    birth_year = c(1993, 1992, 1993, 1992), y0 = c(1, NA, 2, 3),
    treat_2005 = c(0, 0, 1, 1), treat_2010 = NA_real_,
    block_2005 = "a", caste_2005 = "open"
  )
  s <- assignment_sample(d, "y0", 2005)
  expect_equal(as.numeric(tapply(s$w, s$lgd_gp_code, sum)), c(1, 1))
  expect_equal(nrow(s), 3)
  expect_error(assert_unique(data.frame(id = c(1, 1)), "id"), "duplicate")
})

test_that("incoming wives change resident composition without daughters leaving", {
  daughters <- 50
  wives <- c(50, 100)
  expect_equal(daughters / (daughters + wives), c(.5, 1 / 3))
  expect_equal(safe_ratio(c(daughters, daughters), c(100, 100)), c(.5, .5))
  expect_true(is.na(safe_ratio(0, 0)))
  expect_true(is.na(safe_ratio(1, NA_real_)))
})

test_that("source-row IDs distinguish missing legacy keys and preserve filename joins", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path), add = TRUE)
  arrow::write_parquet(data.frame(
    filename = c("roll_a", "roll_a"),
    elector_uid = c("collision", "collision")
  ), path)
  DBI::dbWriteTable(con, "bridge", data.frame(filename = "roll_a"))
  query <- sprintf("SELECT count(*) AS n, count(DISTINCT file_row_number) AS ids
    FROM (SELECT * EXCLUDE(filename), filename || '' AS filename
      FROM read_parquet(%s, filename='parquet_path', file_row_number=true)) e
    JOIN bridge b USING(filename)", DBI::dbQuoteString(con, path))
  result <- DBI::dbGetQuery(con, query)
  expect_equal(result$n, 2)
  expect_equal(result$ids, 2)
})

test_that("SQL scoring agrees with the original zero-prefix Jaro distance", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  a <- c("ram kumar", "sita", "martha", "abc", "", NA)
  b <- c("ramkumar", "gita", "marhta", "xyz", "a", "ram")
  DBI::dbWriteTable(con, "names", data.frame(a = a, b = b))
  actual <- DBI::dbGetQuery(con, "SELECT 1 - jaro_similarity(a, b) AS d FROM names")$d
  expected <- stringdist::stringdist(a, b, method = "jw", p = 0)
  expect_equal(actual, expected, tolerance = 1e-12)
})

test_that("weighted absorption reproduces assignment coefficients and cluster scores", {
  set.seed(104)
  d <- expand.grid(gp = 1:60, birth_year = 1990:1994)
  d$lgd_gp_code <- d$gp
  d$block <- as.character(ceiling(d$gp / 6))
  d$stratum <- interaction(d$block, d$gp %% 2)
  d$treatment <- as.numeric(d$gp %% 3 == 0)
  d$treat_2005 <- as.numeric(d$gp %% 4 == 0)
  d$w <- runif(nrow(d), .5, 2)
  d$y <- .2 * d$treatment + .1 * d$treat_2005 + rnorm(nrow(d))
  for (wave in c(2005, 2010)) {
    full <- assignment_model(d, wave)
    reduced <- bootstrap_model(d, wave)$model
    expect_equal(unname(coef(full)["treatment"]), unname(coef(reduced)["treatment"]), tolerance = 1e-10)
    expect_equal(unname(stats::resid(full) * sqrt(d$w)), unname(stats::resid(reduced)), tolerance = 1e-10)
  }
})
