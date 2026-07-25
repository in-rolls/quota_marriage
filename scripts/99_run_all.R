# 99_run_all.R
# Run the full pipeline. Execute from project root: Rscript scripts/99_run_all.R
# Runner structure vendored from quota_raj/scripts/99_run_all.R @ c6900d1.

library(here)

message("=======================================================")
message("   QUOTA_SHAADI: Full Pipeline")
message("=======================================================")

dir.create(here("logs"), showWarnings = FALSE)
log_file <- here("logs", paste0("pipeline_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))

log_msg <- function(msg, level = "INFO") {
    timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    line <- sprintf("[%s] %s: %s", timestamp, level, msg)
    message(line)
    cat(line, "\n", file = log_file, append = TRUE)
}

log_msg("Pipeline started")
log_msg(paste("Log file:", log_file))

results <- list()
warning_count <- 0L

run_script <- function(script_name) {
    message("\n-------------------------------------------------------")
    message("Running: ", script_name)
    message("-------------------------------------------------------")

    log_msg(paste("Starting:", script_name))
    start_time <- Sys.time()

    had_warning <- FALSE
    warning_messages <- character()

    tryCatch({
        withCallingHandlers({
            source(here("scripts", script_name))
        }, warning = function(w) {
            had_warning <<- TRUE
            warning_messages <<- c(warning_messages, conditionMessage(w))
            log_msg(paste("WARNING in", script_name, ":", conditionMessage(w)), "WARN")
            invokeRestart("muffleWarning")
        })

        elapsed <- round(difftime(Sys.time(), start_time, units = "secs"), 1)

        if (had_warning) {
            warning_count <<- warning_count + length(warning_messages)
            log_msg(paste("SUCCESS WITH WARNINGS:", script_name, "(", elapsed, "s)"), "WARN")
            results[[script_name]] <<- "warning"
            return("warning")
        }

        log_msg(paste("SUCCESS:", script_name, "(", elapsed, "s)"))
        results[[script_name]] <<- "success"
        return("success")
    }, error = function(e) {
        elapsed <- round(difftime(Sys.time(), start_time, units = "secs"), 1)
        log_msg(paste("ERROR in", script_name, ":", e$message), "ERROR")
        results[[script_name]] <<- "error"
        stop(sprintf("Pipeline halted at %s after %ss: %s", script_name, elapsed, e$message))
    })
}

message("\n### PHASE 1: ACQUISITION ###")
log_msg("=== PHASE 1: ACQUISITION ===")
run_script("01a_download_rolls.R")
run_script("01b_import_quota_raj.R")

message("\n### PHASE 2: INGEST + CLEAN ###")
log_msg("=== PHASE 2: INGEST + CLEAN ===")
run_script("02a_rolls_to_parquet.R")
run_script("02b_clean_electors.R")

message("\n### PHASE 3: BRIDGE ###")
log_msg("=== PHASE 3: BRIDGE ===")
run_script("03a_ps_directory.R")
run_script("03b_ps_gp_match_raj.R")
run_script("03c_ps_gp_match_up.R")
run_script("03d_ps_treatment_join.R")
run_script("03e_audit_bridge_balance.R")

message("\n### PHASE 4: OUTCOMES ###")
log_msg("=== PHASE 4: OUTCOMES ===")
run_script("04a_husband_linkage.R")
run_script("04b_cohort_aggregates.R")
run_script("05a_exposure.R")

message("\n### PHASE 5: ESTIMATION ###")
log_msg("=== PHASE 5: ESTIMATION ===")
run_script("06a_couples_design.R")
run_script("06b_natal_design.R")
run_script("06c_random_rotation.R")
run_script("06d_placebo.R")
run_script("06e_sensitivity.R")
run_script("06f_early_marriage.R")
run_script("07a_balance.R")

message("\n### PHASE 6: VALIDATION ###")
log_msg("=== PHASE 6: VALIDATION ===")
run_script("08a_validate_benchmarks.R")

message("\n=======================================================")
message("   PIPELINE SUMMARY")
message("=======================================================")
for (s in names(results)) {
    message(sprintf("  %-35s %s", s, results[[s]]))
}
log_msg(sprintf("Pipeline finished: %d scripts, %d warnings",
                length(results), warning_count))
