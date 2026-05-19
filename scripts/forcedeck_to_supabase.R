# ============================================================================
# forcedeck_to_supabase.R
# ----------------------------------------------------------------------------
# PURPOSE:
#   Reads a raw ForceDeck CMJ CSV export, cleans and maps the columns to
#   your Supabase cmj_tests table schema, matches athletes by name, and
#   inserts new test results via the Supabase REST API.
#
# WHEN TO RUN THIS:
#   After each ForceDeck testing session (typically weekly or bi-weekly).
#   You do NOT need this during testing — your seed_data.sql already has
#   simulated CMJ data. Run this only at go-live.
#
# REQUIREMENTS:
#   install.packages(c("httr2", "readr", "dplyr", "stringr", "lubridate"))
#
# FORCEDECK EXPORT STEPS:
#   1. Open the Vald Performance Hub (web app) or ForceDeck desktop app
#   2. Go to Results → select your testing session
#   3. Export → CSV (select "CMJ" test type)
#   4. Save the file and set FORCEDECK_CSV_PATH below
#
# NOTE ON METRICS:
#   ForceDeck computes RSI-Modified, Concentric Impulse, and Eccentric
#   Deceleration Impulse internally. This script maps them directly.
#   If your export is missing any metric, the column will be filled with
#   NA and that column will be excluded from the insert.
# ============================================================================

library(httr2)
library(readr)
library(dplyr)
library(stringr)
library(lubridate)

# ============================================================================
# CONFIG — edit these before running
# ============================================================================
FORCEDECK_CSV_PATH <- "path/to/your/forcedeck_export.csv"   # ← update this
SUPABASE_URL       <- "https://fyhgvxfrwbwuqxllodip.supabase.co"                    # ← same as supabase_client.js
SUPABASE_KEY       <- "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U"               # ← same as supabase_client.js
DRY_RUN            <- TRUE   # TRUE = preview only. Set FALSE to actually insert.
# ============================================================================

cat("=============================================================\n")
cat("  UF S&C — ForceDeck CMJ Import\n")
cat("=============================================================\n")
cat("CSV path:", FORCEDECK_CSV_PATH, "\n")
cat("Dry run: ", DRY_RUN, "\n\n")

# ── Step 1: Load the CSV ─────────────────────────────────────────────────────
if (!file.exists(FORCEDECK_CSV_PATH)) {
  stop("CSV file not found at: ", FORCEDECK_CSV_PATH,
       "\nUpdate FORCEDECK_CSV_PATH at the top of this script.")
}

raw <- read_csv(FORCEDECK_CSV_PATH, show_col_types = FALSE)
cat("Loaded CSV:", nrow(raw), "rows,", ncol(raw), "columns\n")
cat("Columns found:", paste(names(raw), collapse = ", "), "\n\n")

# ── Step 2: Map ForceDeck column names to our schema ─────────────────────────
# ForceDeck / Vald Hub exports use these column names (as of 2024 firmware).
# If your version uses different names, add them to the candidate lists below.
col_map <- list(
  athlete_name              = c("Athlete", "Name", "Player", "athlete_name", "Athlete Name"),
  test_date                 = c("Date", "Test Date", "date", "test_date", "Session Date"),
  jump_height_cm            = c("Jump Height (cm)", "JumpHeight", "Jump Height",
                                 "CMJ Height (cm)", "Height (cm)"),
  peak_force_n              = c("Peak Force (N)", "PeakForce", "Peak Force",
                                 "Max Force (N)", "Peak Vaulting Force (N)"),
  peak_power_w              = c("Peak Power (W)", "PeakPower", "Peak Power",
                                 "Max Power (W)"),
  rsi_modified              = c("RSI-Modified", "RSImod", "RSI Mod", "Modified RSI",
                                 "RSI Modified", "rsi_modified"),
  concentric_impulse_ns     = c("Concentric Impulse (Ns)", "Concentric Impulse",
                                 "Con Impulse", "concentric_impulse"),
  eccentric_decel_impulse_ns= c("Eccentric Deceleration Impulse (Ns)",
                                 "Eccentric Decel Impulse", "Ecc Decel Impulse",
                                 "eccentric_decel_impulse", "Braking Impulse (Ns)"),
  asymmetry_index_pct       = c("Asymmetry (%)", "Asymmetry Index", "Asymmetry",
                                 "asymmetry_index_pct", "Force Asymmetry (%)")
)

find_col <- function(df, candidates) {
  match <- intersect(candidates, names(df))
  if (length(match) == 0) return(NULL)
  match[1]
}

clean <- raw
for (target in names(col_map)) {
  found <- find_col(raw, col_map[[target]])
  if (!is.null(found)) {
    clean <- clean %>% rename(!!target := !!found)
    cat("  Mapped:", found, "->", target, "\n")
  } else {
    cat("  WARNING: No column found for", target,
        "(tried:", paste(col_map[[target]], collapse=", "), ")\n")
  }
}

# Keep only our target columns
our_cols  <- names(col_map)
available <- intersect(our_cols, names(clean))
clean     <- clean %>% select(all_of(available))

# ── Step 3: Filter for CMJ test type if a Type column exists ─────────────────
if ("Test Type" %in% names(raw)) {
  n_before <- nrow(clean)
  raw_type <- raw %>% select(`Test Type`) %>% slice(seq_len(nrow(clean)))
  clean    <- bind_cols(clean, raw_type)
  clean    <- clean %>%
    filter(str_detect(`Test Type`, regex("CMJ|Countermovement", ignore_case = TRUE)))
  cat("\nFiltered to CMJ test type:", nrow(clean), "of", n_before, "rows retained\n")
  clean <- clean %>% select(-`Test Type`)
}

# ── Step 4: Clean ────────────────────────────────────────────────────────────
cat("\nCleaning data...\n")

if ("athlete_name" %in% names(clean)) {
  clean <- clean %>%
    mutate(athlete_name = str_to_title(str_trim(athlete_name)))
}

if ("test_date" %in% names(clean)) {
  clean <- clean %>%
    mutate(test_date = case_when(
      !is.na(parse_date_time(test_date, orders = "mdy", quiet = TRUE)) ~
        format(parse_date_time(test_date, orders = "mdy"), "%Y-%m-%d"),
      !is.na(parse_date_time(test_date, orders = "dmy", quiet = TRUE)) ~
        format(parse_date_time(test_date, orders = "dmy"), "%Y-%m-%d"),
      !is.na(ymd(test_date, quiet = TRUE)) ~
        format(ymd(test_date), "%Y-%m-%d"),
      TRUE ~ NA_character_
    ))
}

numeric_cols <- c("jump_height_cm","peak_force_n","peak_power_w","rsi_modified",
                  "concentric_impulse_ns","eccentric_decel_impulse_ns","asymmetry_index_pct")
for (col in intersect(numeric_cols, names(clean))) {
  clean[[col]] <- suppressWarnings(as.numeric(clean[[col]]))
}

# Some ForceDeck exports give jump height in mm — convert if > 200 (no human jumps 200cm)
if ("jump_height_cm" %in% names(clean)) {
  clean <- clean %>%
    mutate(jump_height_cm = if_else(jump_height_cm > 200, jump_height_cm / 10, jump_height_cm))
}

# Asymmetry is sometimes given as a decimal (0.05 = 5%) — normalize to pct
if ("asymmetry_index_pct" %in% names(clean)) {
  clean <- clean %>%
    mutate(asymmetry_index_pct = if_else(asymmetry_index_pct < 1,
                                          asymmetry_index_pct * 100,
                                          asymmetry_index_pct))
}

n_before <- nrow(clean)
clean <- clean %>%
  filter(!is.na(athlete_name), athlete_name != "",
         !is.na(test_date),
         !is.na(jump_height_cm), jump_height_cm > 0)
cat("  Dropped", n_before - nrow(clean), "invalid rows\n")
cat("  Rows after cleaning:", nrow(clean), "\n\n")

# ── Step 5: Match athletes to Supabase UUIDs ─────────────────────────────────
cat("Fetching athlete list from Supabase...\n")

tryCatch({
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/athletes")) %>%
    req_headers(
      "apikey"        = SUPABASE_KEY,
      "Authorization" = paste("Bearer", SUPABASE_KEY)
    ) %>%
    req_url_query(select = "id,name") %>%
    req_perform()
  athletes_db <- resp %>% resp_body_json(simplifyVector = TRUE) %>% as.data.frame()
  cat("  Found", nrow(athletes_db), "athletes in Supabase\n")
}, error = function(e) {
  stop("Failed to fetch athletes: ", e$message)
})

match_athlete_id <- function(name, db) {
  exact <- db$id[str_to_title(db$name) == name]
  if (length(exact) > 0) return(exact[1])
  last  <- str_extract(name, "\\S+$")
  last_match <- db$id[str_detect(str_to_title(db$name), fixed(last))]
  if (length(last_match) == 1) return(last_match[1])
  return(NA_character_)
}

clean <- clean %>%
  rowwise() %>%
  mutate(athlete_id = match_athlete_id(athlete_name, athletes_db)) %>%
  ungroup()

unmatched <- clean %>% filter(is.na(athlete_id))
if (nrow(unmatched) > 0) {
  cat("\n  WARNING:", nrow(unmatched), "unmatched athletes (will be skipped):\n")
  print(unique(unmatched$athlete_name))
}

clean <- clean %>% filter(!is.na(athlete_id))
cat("  Matched", nrow(clean), "rows\n\n")

# ── Step 6: Deduplicate — skip tests already in DB for same athlete + date ────
cat("Checking for duplicate tests already in Supabase...\n")

tryCatch({
  existing_resp <- request(paste0(SUPABASE_URL, "/rest/v1/cmj_tests")) %>%
    req_headers("apikey" = SUPABASE_KEY, "Authorization" = paste("Bearer", SUPABASE_KEY)) %>%
    req_url_query(select = "athlete_id,test_date") %>%
    req_perform()
  existing <- existing_resp %>% resp_body_json(simplifyVector = TRUE) %>% as.data.frame()

  if (nrow(existing) > 0) {
    existing_keys <- paste(existing$athlete_id, existing$test_date, sep = "_")
    new_keys      <- paste(clean$athlete_id,    clean$test_date,    sep = "_")
    dupes         <- sum(new_keys %in% existing_keys)
    clean         <- clean[!new_keys %in% existing_keys, ]
    if (dupes > 0) cat("  Skipped", dupes, "duplicate rows (same athlete + date already in DB)\n")
  }
  cat("  Rows to insert after dedup:", nrow(clean), "\n\n")
}, error = function(e) {
  cat("  Could not check for duplicates (proceeding anyway):", e$message, "\n\n")
})

# ── Step 7: Build payload ─────────────────────────────────────────────────────
required_cols <- c("athlete_id","test_date","jump_height_cm","peak_force_n",
                   "peak_power_w","rsi_modified","concentric_impulse_ns",
                   "eccentric_decel_impulse_ns","asymmetry_index_pct")

missing_required <- setdiff(required_cols, names(clean))
if (length(missing_required) > 0) {
  cat("WARNING: The following required columns are missing from your export:\n")
  cat(" ", paste(missing_required, collapse = ", "), "\n")
  cat("  These will default to 0. Check your ForceDeck export settings.\n\n")
  for (col in missing_required) clean[[col]] <- 0
}

payload <- clean %>%
  select(all_of(required_cols)) %>%
  mutate(across(where(is.numeric), ~round(.x, 3)))

cat("Preview of first 5 rows:\n")
print(head(payload, 5))
cat("\nTotal rows ready to insert:", nrow(payload), "\n\n")

# ── Step 8: Upload ───────────────────────────────────────────────────────────
if (DRY_RUN) {
  cat("=============================================================\n")
  cat("  DRY RUN — no data uploaded.\n")
  cat("  If the preview looks correct, set DRY_RUN <- FALSE and re-run.\n")
  cat("=============================================================\n")
} else {
  cat("Uploading to Supabase cmj_tests table...\n")
  batch_size <- 100
  batches    <- split(payload, ceiling(seq_len(nrow(payload)) / batch_size))
  success    <- 0
  failed     <- 0

  for (i in seq_along(batches)) {
    tryCatch({
      request(paste0(SUPABASE_URL, "/rest/v1/cmj_tests")) %>%
        req_headers(
          "apikey"        = SUPABASE_KEY,
          "Authorization" = paste("Bearer", SUPABASE_KEY),
          "Content-Type"  = "application/json",
          "Prefer"        = "return=minimal"
        ) %>%
        req_body_json(batches[[i]]) %>%
        req_perform()
      success <- success + nrow(batches[[i]])
      cat("  Batch", i, "—", nrow(batches[[i]]), "rows inserted\n")
    }, error = function(e) {
      failed <<- failed + nrow(batches[[i]])
      cat("  ERROR in batch", i, ":", e$message, "\n")
    })
  }

  cat("\n=============================================================\n")
  cat("  Upload complete. Inserted:", success, "| Failed:", failed, "\n")
  cat("=============================================================\n")
}
