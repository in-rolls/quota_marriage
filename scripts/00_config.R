# 00_config.R
# Central configuration for quota_marriage

library(here)

# DATAVERSE (parsed electoral rolls)
# =============================================================================

DATAVERSE_SERVER <- "dataverse.harvard.edu"
ROLL_DOI <- "doi:10.7910/DVN/MUEGDT"

ROLL_FILES <- list(
    raj = "rajasthan_all_clean+t13n.csv.gz",
    up  = c("up_all_clean+t13n.csv.gz.partaa",
            "up_all_clean+t13n.csv.gz.partab",
            "up_all_clean+t13n.csv.gz.partac")
)

# Asserted against the modal `year` column at 02b (which wins on mismatch).
# The electoral_rolls README table says Rajasthan 2014 / UP 2018, but the
# data's year columns are Rajasthan 2018 (Draftroll_2018.aspx) and UP 2017.
ROLL_YEAR <- c(raj = 2018L, up = 2017L)

# Approximate published electorate sizes; 02a flags >10% deviation
EXPECTED_ELECTORS <- c(raj = 41e6, up = 140e6)

# =============================================================================
# RESERVATION CYCLES AND EXPOSURE
# =============================================================================

CYCLES <- list(
    raj = list("2005" = c(2005, 2010), "2010" = c(2010, 2015), "2015" = c(2015, 2020)),
    up  = list("2005" = c(2005, 2010), "2010" = c(2010, 2015), "2015" = c(2015, 2021))
)

EXPOSURE_WINDOWS <- list(main = c(5, 15), alt1 = c(6, 16), alt2 = c(10, 16))

AGE_MIN <- 18L
AGE_MAX <- 110L

# =============================================================================
# MATCHING THRESHOLDS (Jaro distances; stringdist jw with p = 0)
# =============================================================================

JW_VILLAGE_DISTRICT <- 0.15
JW_VILLAGE_TEHSIL <- 0.20
JW_HUSBAND <- 0.15
JW_HUSBAND_MARGIN <- 0.05

# =============================================================================
# DUCKDB
# =============================================================================

DUCKDB_MEMORY_LIMIT <- Sys.getenv("DUCKDB_MEMORY_LIMIT", unset = "16GB")
DUCKDB_THREADS <- as.integer(Sys.getenv("DUCKDB_THREADS", unset = "8"))
