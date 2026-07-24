# 00_config.R
# Central configuration for quota_shaadi

library(here)

# =============================================================================
# EXTERNAL REPO PATHS (read-only; snapshotted by 01b)
# =============================================================================

QUOTA_RAJ_DIR <- Sys.getenv("QUOTA_RAJ_DIR",
    unset = normalizePath(file.path(here(), "..", "quota_raj"), mustWork = FALSE))
DELIM_RAJ_DIR <- Sys.getenv("DELIM_RAJ_DIR",
    unset = normalizePath(file.path(here(), "..", "delim_raj"), mustWork = FALSE))

# =============================================================================
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
# The electoral_rolls README table says Rajasthan 2014, but the scraper pulled
# the 2018 draft roll (Draftroll_2018.aspx) and the data's year column is 2018.
ROLL_YEAR <- c(raj = 2018L, up = 2018L)

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

PLACEBO_MAX_BIRTH_YEAR <- 1985L

AGE_MIN <- 18L
AGE_MAX <- 110L

# =============================================================================
# MATCHING THRESHOLDS (Jaro-Winkler distances)
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

# =============================================================================
# TABLE DICTIONARIES AND NOTES
# =============================================================================

DICT_MAIN <- c(
    "dose_main" = "Exposure dose (ages 5--15)",
    "dose_alt1" = "Exposure dose (ages 6--16)",
    "dose_alt2" = "Exposure dose (ages 10--16)",
    "any_exposure" = "Any exposure",
    "exp_2005" = "$\\text{Quota}_{2005} \\times$ exposed cohort",
    "exp_2010" = "$\\text{Quota}_{2010} \\times$ exposed cohort",
    "exp_2015" = "$\\text{Quota}_{2015} \\times$ exposed cohort",
    "mean_gap" = "Mean spousal age gap",
    "share_gap_ge5" = "Share gap $\\geq$ 5",
    "share_married_w" = "Share of women married",
    "natal_share_w" = "Share women in natal home",
    "natal_ratio" = "Natal daughters / natal sons",
    "lgd_gp_code" = "GP",
    "birth_year" = "Birth cohort",
    "district_std" = "District",
    "dist_samiti_2010" = "(District, Samiti)",
    "dist_block_2010" = "(District, Block)"
)

NOTES_SIGNIF <- "$^{***}$p$<$0.01; $^{**}$p$<$0.05; $^{*}$p$<$0.1."

NOTES_COUPLES <- paste0(
    NOTES_SIGNIF,
    " Cells are GP $\\times$ wife birth cohort; weights are cell couple counts;",
    " standard errors clustered by GP.",
    " Treatment is the reservation history of the couple's GP of residence;",
    " given patrilocal exogamy this identifies husband-side/marriage-market",
    " exposure, not the bride's own childhood exposure."
)

NOTES_NATAL <- paste0(
    NOTES_SIGNIF,
    " Cells are GP $\\times$ birth cohort; weights are cell counts of women;",
    " standard errors clustered by GP.",
    " Because daughters exit the natal roll at marriage, presence in the natal",
    " household at the observed age is itself the marriage-timing outcome."
)

# =============================================================================
# FIGURE SETTINGS (vendored from quota_raj/scripts/00_config.R @ c6900d1)
# =============================================================================

theme_pub <- function(base_size = 11, base_family = "") {
    ggplot2::theme_bw(base_size = base_size, base_family = base_family) +
    ggplot2::theme(
        panel.grid.major = ggplot2::element_blank(),
        panel.grid.minor = ggplot2::element_blank(),
        panel.border = ggplot2::element_rect(color = "gray30", fill = NA, linewidth = 0.5),
        axis.ticks = ggplot2::element_line(color = "gray30", linewidth = 0.3),
        axis.text = ggplot2::element_text(color = "gray20"),
        axis.title = ggplot2::element_text(color = "gray10", face = "plain"),
        legend.background = ggplot2::element_blank(),
        legend.key = ggplot2::element_blank(),
        legend.title = ggplot2::element_text(face = "plain", size = ggplot2::rel(0.9)),
        strip.background = ggplot2::element_blank(),
        strip.text = ggplot2::element_text(face = "bold", hjust = 0),
        plot.margin = ggplot2::margin(10, 10, 10, 10),
        plot.title = ggplot2::element_text(face = "bold", hjust = 0, size = ggplot2::rel(1.1)),
        plot.subtitle = ggplot2::element_text(color = "gray40", hjust = 0)
    )
}

COLORS_PUB <- c(
    primary = "#2C3E50",
    secondary = "#7F8C8D",
    accent = "#C0392B",
    highlight = "#27AE60",
    light = "#BDC3C7"
)

FIG_WIDTH_FULL <- 6.5
FIG_WIDTH_HALF <- 3.25
FIG_HEIGHT <- 4.5
