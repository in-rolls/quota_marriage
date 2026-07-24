# 02b_clean_electors.R
# Typed, cleaned elector-level dataset per state. The polling-part key is the
# source PDF `filename` (one PDF = one AC-part); households are
# (filename, cleaned house number).

library(here)
library(dplyr)
library(DBI)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

con <- get_duck()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

SEX_MAP_SQL <- "
    CASE
        WHEN lower(strip_accents(coalesce(nullif(trim(sex), ''), ''))) IN
             ('m', 'male', 'purush', 'pu') THEN 'm'
        WHEN trim(sex) IN ('पुरुष', 'पु', 'पुरूष', 'नर') THEN 'm'
        WHEN lower(strip_accents(coalesce(nullif(trim(sex), ''), ''))) IN
             ('f', 'female', 'mahila', 'stri') THEN 'f'
        WHEN trim(sex) IN ('महिला', 'स्त्री', 'औरत') THEN 'f'
        WHEN lower(strip_accents(coalesce(nullif(trim(sex), ''), ''))) IN
             ('t', 'third', 'third gender', 'o', 'other') THEN 't'
        WHEN trim(sex) IN ('तृतीय', 'अन्य') THEN 't'
        ELSE NULL
    END"

REL_MAP_SQL <- "
    CASE
        WHEN lower(trim(relationship)) IN ('father', 'husband', 'mother', 'other')
            THEN lower(trim(relationship))
        WHEN trim(relationship) LIKE 'पति%' THEN 'husband'
        WHEN trim(relationship) LIKE 'पिता%' THEN 'father'
        WHEN trim(relationship) LIKE 'माता%' OR trim(relationship) LIKE 'मां%' THEN 'mother'
        WHEN relationship IS NULL OR trim(relationship) = '' THEN NULL
        ELSE 'other'
    END"

for (state in c("raj", "up")) {
    rolls_glob <- here("data", "rolls", state, "*", "*.parquet")
    out_dir <- here("data", "electors", state)
    done_flag <- file.path(out_dir, ".clean_complete")
    if (file.exists(done_flag)) {
        message("Already cleaned, skipping: ", state)
        next
    }
    unlink(list.files(out_dir, pattern = "^district_part=", full.names = TRUE),
           recursive = TRUE)

    roll_year <- dbGetQuery(con, sprintf("
        SELECT try_cast(year AS INTEGER) AS y, count(*) AS n
        FROM read_parquet(%s, hive_partitioning = true)
        WHERE try_cast(year AS INTEGER) IS NOT NULL
        GROUP BY 1 ORDER BY n DESC LIMIT 1",
        dbQuoteString(con, rolls_glob)))$y

    if (roll_year != ROLL_YEAR[[state]]) {
        warning(sprintf("%s: modal roll year %d differs from configured %d; using %d",
                        state, roll_year, ROLL_YEAR[[state]], roll_year))
    }
    if (roll_year < 2010 || roll_year > 2024) {
        stop(sprintf("%s: implausible modal roll year %d", state, roll_year))
    }

    message(sprintf("Cleaning %s (roll year %d)", state, roll_year))

    dbExecute(con, sprintf("
        COPY (
            SELECT
                '%s' AS state,
                %d AS roll_year,
                md5(concat_ws('|', filename, part_no, number, id)) AS elector_uid,
                district_part,
                nullif(trim(district), '') AS district_dev,
                lower(strip_accents(nullif(trim(district_t13n), ''))) AS district_std,
                filename,
                try_cast(part_no AS INTEGER) AS part_no,
                nullif(regexp_replace(regexp_replace(lower(coalesce(house_no, '')),
                        '[[:punct:][:space:]]+', '', 'g'), '^0+', ''), '') AS house_no_clean,
                nfc_normalize(regexp_replace(regexp_replace(coalesce(elector_name, ''),
                        '[\\x{200b}-\\x{200d}\\x{feff}\\x{0964}\\x{0965}]', ' ', 'g'),
                        '\\s+', ' ', 'g')) AS name_dev,
                nullif(trim(regexp_replace(regexp_replace(
                        lower(strip_accents(coalesce(elector_name_t13n, ''))),
                        '[[:punct:]]', '', 'g'), '\\s+', ' ', 'g')), '') AS name_std,
                nfc_normalize(regexp_replace(regexp_replace(coalesce(father_or_husband_name, ''),
                        '[\\x{200b}-\\x{200d}\\x{feff}\\x{0964}\\x{0965}]', ' ', 'g'),
                        '\\s+', ' ', 'g')) AS rel_name_dev,
                nullif(trim(regexp_replace(regexp_replace(
                        lower(strip_accents(coalesce(father_or_husband_name_t13n, ''))),
                        '[[:punct:]]', '', 'g'), '\\s+', ' ', 'g')), '') AS rel_name_std,
                %s AS relation_type,
                %s AS sex_std,
                CASE WHEN try_cast(age AS INTEGER) BETWEEN %d AND %d
                     THEN try_cast(age AS INTEGER) ELSE NULL END AS age,
                %d - CASE WHEN try_cast(age AS INTEGER) BETWEEN %d AND %d
                          THEN try_cast(age AS INTEGER) ELSE NULL END AS birth_year
            FROM read_parquet(%s, hive_partitioning = true)
        ) TO %s (FORMAT PARQUET, PARTITION_BY (district_part),
                 OVERWRITE_OR_IGNORE, COMPRESSION ZSTD)",
        state, roll_year, REL_MAP_SQL, SEX_MAP_SQL,
        AGE_MIN, AGE_MAX, roll_year, AGE_MIN, AGE_MAX,
        dbQuoteString(con, rolls_glob),
        dbQuoteString(con, out_dir)))

    electors_glob <- file.path(out_dir, "*", "*.parquet")

    clean_stats <- dbGetQuery(con, sprintf("
        SELECT
            count(*) AS n_rows,
            avg(CASE WHEN age IS NOT NULL THEN 1.0 ELSE 0 END) AS share_valid_age,
            avg(CASE WHEN sex_std IS NOT NULL THEN 1.0 ELSE 0 END) AS share_sex_mapped,
            avg(CASE WHEN relation_type IS NOT NULL THEN 1.0 ELSE 0 END) AS share_relation_mapped,
            avg(CASE WHEN house_no_clean IS NOT NULL THEN 1.0 ELSE 0 END) AS share_with_house,
            avg(CASE WHEN name_std IS NOT NULL THEN 1.0 ELSE 0 END) AS share_with_name_t13n,
            count(DISTINCT filename) AS n_parts
        FROM read_parquet(%s, hive_partitioning = true)",
        dbQuoteString(con, electors_glob)))

    unmapped_sex <- dbGetQuery(con, sprintf("
        SELECT sex, count(*) AS n
        FROM read_parquet(%s, hive_partitioning = true)
        WHERE %s IS NULL AND sex IS NOT NULL AND trim(sex) != ''
        GROUP BY sex ORDER BY n DESC LIMIT 50",
        dbQuoteString(con, file.path(here("data", "rolls", state), "*", "*.parquet")),
        SEX_MAP_SQL))

    age_dist <- dbGetQuery(con, sprintf("
        SELECT sex_std, age, count(*) AS n
        FROM read_parquet(%s, hive_partitioning = true)
        WHERE age IS NOT NULL
        GROUP BY sex_std, age ORDER BY sex_std, age",
        dbQuoteString(con, electors_glob)))

    whipple <- age_dist |>
        filter(age >= 23, age <= 62) |>
        summarise(
            whipple = 500 * sum(n[age %% 5 == 0]) / sum(n)
        )

    rel_by_age <- dbGetQuery(con, sprintf("
        SELECT sex_std, age, relation_type, count(*) AS n
        FROM read_parquet(%s, hive_partitioning = true)
        WHERE age IS NOT NULL AND sex_std IS NOT NULL
        GROUP BY sex_std, age, relation_type",
        dbQuoteString(con, electors_glob)))

    write_audit(clean_stats |> mutate(state = state, roll_year = roll_year),
                sprintf("02b_%s_clean_stats.csv", state))
    write_audit(unmapped_sex, sprintf("02b_%s_unmapped_sex_values.csv", state))
    write_audit(age_dist, sprintf("02b_%s_age_distribution.csv", state))
    write_audit(whipple |> mutate(state = state), sprintf("02b_%s_whipple.csv", state))
    write_audit(rel_by_age, sprintf("02b_%s_relation_by_age.csv", state))

    if (clean_stats$share_sex_mapped < 0.95) {
        warning(sprintf("%s: only %.1f%% of sex values mapped — inspect 02b_%s_unmapped_sex_values.csv",
                        state, 100 * clean_stats$share_sex_mapped, state))
    }

    file.create(done_flag)
}

message("02b complete")
