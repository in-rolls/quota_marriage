library(testthat)
library(dplyr)
source('scripts/00_sources.R')
test_that('source manifest rejects unknown files and corrupted cache entries', {
    expect_error(source_path('unlisted'), 'Unpinned source')
    cache <- withr::local_tempdir()
    withr::local_envvar(c(INDIA_DATA_HOME = cache))
    spec <- jsonlite::read_json('data/sources.json')$raj_lgd_directory
    path <- file.path(cache, spec$provider, spec$ref, spec$path)
    dir.create(dirname(path), recursive = TRUE)
    writeLines('damaged', path)
    expect_error(source_path('raj_lgd_directory'), 'Cached source checksum mismatch')
})
test_that('canonical treatment panels preserve source anchors and reservation assignments', {
    for (state in c('raj', 'up')) for (four_cycle in c(FALSE, TRUE)) {
        waves <- if (four_cycle) {
            if (state == 'raj') c(2005, 2010, 2015, 2020) else c(2005, 2010, 2015, 2021)
        } else c(2005, 2010)
        raw <- arrow::read_parquet(source_path(paste0(state, '_panel_', paste(waves, collapse = '_'))))
        actual <- treatment_panel(state, four_cycle)
        if (state == 'up') raw <- raw |> filter(if_all(all_of(paste0('women_reserved_', waves)), ~ !is.na(.x)))
        expect_equal(nrow(actual), nrow(raw))
        if (state == 'up') {
            expect_identical(actual$key_2010, raw$key_2010)
            for (wave in waves) expect_equal(actual[[paste0('treat_', wave)]], as.integer(raw[[paste0('women_reserved_', wave)]]))
        } else {
            expect_identical(actual$match_key, raw$match_key)
            for (wave in waves) expect_identical(actual[[paste0('treat_', wave)]], raw[[paste0('treat_', wave)]])
        }
    }
})
