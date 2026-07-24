# 02a_rolls_to_parquet.R
# Ingest the raw csv.gz rolls into hive-partitioned parquet, one dataset per
# state, partitioned by a filesystem-safe district key. All columns kept as
# VARCHAR; typing happens in 02b.

library(here)
library(dplyr)
library(DBI)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

STATES <- list(
    raj = here("data", "raw", "rajasthan_all_clean+t13n.csv.gz"),
    up  = here("data", "raw", "up_all_clean+t13n.csv.gz")
)

con <- get_duck()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (state in names(STATES)) {
    src <- STATES[[state]]
    if (!file.exists(src)) {
        message("Raw file not yet present, skipping: ", state)
        next
    }
    out_dir <- here("data", "rolls", state)
    done_flag <- file.path(out_dir, ".ingest_complete")
    if (file.exists(done_flag)) {
        message("Already ingested, skipping: ", state)
        next
    }
    unlink(list.files(out_dir, pattern = "^district_part=", full.names = TRUE),
           recursive = TRUE)

    message("Ingesting ", state, " from ", basename(src))

    dbExecute(con, sprintf("
        CREATE OR REPLACE TABLE rejects_scan AS
        SELECT * FROM read_csv(%s,
            header = true,
            all_varchar = true,
            store_rejects = true,
            rejects_table = 'csv_rejects',
            rejects_limit = 100000
        ) LIMIT 0", dbQuoteString(con, src)))

    dbExecute(con, sprintf("
        COPY (
            SELECT *,
                coalesce(
                    nullif(regexp_replace(lower(strip_accents(district_t13n)),
                                          '[^a-z0-9]+', '_', 'g'), ''),
                    'missing') AS district_part
            FROM read_csv(%s,
                header = true,
                all_varchar = true,
                store_rejects = true,
                rejects_table = 'csv_rejects',
                rejects_limit = 100000
            )
        ) TO %s (FORMAT PARQUET, PARTITION_BY (district_part),
                 OVERWRITE_OR_IGNORE, COMPRESSION ZSTD)",
        dbQuoteString(con, src), dbQuoteString(con, out_dir)))

    n_rejects <- dbGetQuery(con, "SELECT count(*) AS n FROM csv_rejects")$n

    stats <- dbGetQuery(con, sprintf("
        SELECT district_part,
               count(*) AS n_rows,
               count(DISTINCT filename) AS n_files,
               count(DISTINCT year) AS n_year_values
        FROM read_parquet(%s, hive_partitioning = true)
        GROUP BY district_part ORDER BY district_part",
        dbQuoteString(con, file.path(out_dir, "*", "*.parquet"))))

    n_total <- sum(stats$n_rows)
    expected <- EXPECTED_ELECTORS[[state]]
    deviation <- abs(n_total - expected) / expected
    message(sprintf("%s: %s rows ingested (expected ~%s, deviation %.1f%%), %d rejects",
                    state, format(n_total, big.mark = ","),
                    format(expected, big.mark = ","), 100 * deviation, n_rejects))

    year_dist <- dbGetQuery(con, sprintf("
        SELECT year, count(*) AS n
        FROM read_parquet(%s, hive_partitioning = true)
        GROUP BY year ORDER BY n DESC",
        dbQuoteString(con, file.path(out_dir, "*", "*.parquet"))))

    missing_shares <- dbGetQuery(con, sprintf("
        SELECT
            avg(CASE WHEN elector_name IS NULL OR elector_name = '' THEN 1.0 ELSE 0 END) AS miss_elector_name,
            avg(CASE WHEN father_or_husband_name IS NULL OR father_or_husband_name = '' THEN 1.0 ELSE 0 END) AS miss_rel_name,
            avg(CASE WHEN relationship IS NULL OR relationship = '' THEN 1.0 ELSE 0 END) AS miss_relationship,
            avg(CASE WHEN house_no IS NULL OR house_no = '' THEN 1.0 ELSE 0 END) AS miss_house_no,
            avg(CASE WHEN age IS NULL OR age = '' THEN 1.0 ELSE 0 END) AS miss_age,
            avg(CASE WHEN sex IS NULL OR sex = '' THEN 1.0 ELSE 0 END) AS miss_sex,
            avg(CASE WHEN polling_station_name IS NULL OR polling_station_name = '' THEN 1.0 ELSE 0 END) AS miss_ps_name
        FROM read_parquet(%s, hive_partitioning = true) USING SAMPLE 1 PERCENT (bernoulli)",
        dbQuoteString(con, file.path(out_dir, "*", "*.parquet"))))

    write_audit(stats, sprintf("02a_%s_ingest_by_district.csv", state))
    write_audit(year_dist, sprintf("02a_%s_year_values.csv", state))
    write_audit(missing_shares, sprintf("02a_%s_missing_shares.csv", state))
    write_audit(
        tibble::tibble(state = state, n_rows = n_total, n_rejects = n_rejects,
                       expected = expected, deviation = deviation),
        sprintf("02a_%s_ingest_summary.csv", state))

    if (deviation > 0.10) {
        warning(sprintf("%s row count deviates %.1f%% from expected electorate",
                        state, 100 * deviation))
    }

    file.create(done_flag)
}

message("02a complete")
