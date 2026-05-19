# ============================================================================
# catapult_to_supabase.R
# ----------------------------------------------------------------------------
# PURPOSE:
#   Reads a raw Catapult GPS CSV export, cleans and standardizes the columns,
#   matches athletes to your Supabase athletes table by name, and inserts
#   new sessions into the gps_sessions table via the Supabase REST API.
#
# WHEN TO RUN THIS:
#   After each practice or game when you export data from Catapult OpenField.
#   You do NOT need this during testing — your seed_data.sql already has
#   simulated GPS data. Run this only when you are ready to go live with
#   real Catapult exports.
#
# REQUIREMENTS:
#   Install these R packages once by running in RStudio console:
#     install.packages(c("httr2", "readr", "dplyr", "stringr", "lubridate"))
#
# HOW TO RUN:
#   Option A — RStudio: Open this file, set the CONFIG values below, click
#              Source (or Ctrl+Shift+S)
#   Option B — Terminal: Rscript catapult_to_supabase.R
#
# CATAPULT EXPORT STEPS:
#   1. Open Catapult OpenField
#   2. Select the session(s) you want to export
#   3. Export → CSV → "All Athletes" → save the file
#   4. Set CATAPULT_CSV_PATH below to that file's path
# ============================================================================

library(httr2)
library(readr)
library(dplyr)
library(stringr)
library(lubridate)

# ============================================================================
# CONFIG — edit these before running
# ============================================================================
CATAPULT_CSV_PATH <- "path/to/your/catapult_export.csv"   # ← update this
SUPABASE_URL      <- "https://fyhgvxfrwbwuqxllodip.supabase.co"                   # ← same as supabase_client.js
SUPABASE_KEY      <- "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U"              # ← same as supabase_client.js
DRY_RUN           <- TRUE   # TRUE = preview only, no upload. Set FALSE to actually insert.
# ============================================================================

cat("=============================================================\n")
cat("  UF S&C — Catapult GPS Import\n")
cat("=============================================================\n")
cat("CSV path:", CATAPULT_CSV_PATH, "\n")
cat("Dry run: ", DRY_RUN, "\n\n")

# ── Step 1: Load the CSV ─────────────────────────────────────────────────────
if (!file.exists(CATAPULT_CSV_PATH)) {
  stop("CSV file not found at: ", CATAPULT_CSV_PATH,
       "\nUpdate CATAPULT_CSV_PATH at the top of this script.")
}

raw <- read_csv(CATAPULT_CSV_PATH, show_col_types = FALSE)
cat("Loaded CSV:", nrow(raw), "rows,", ncol(raw), "columns\n")
cat("Columns found:", paste(names(raw), collapse = ", "), "\n\n")

# ── Step 2: Map Catapult column names to our schema ──────────────────────────
# Catapult exports vary by firmware version. This mapping covers the most
# common column names. If your export has different names, add them here.
#
# Format: "OUR_NAME" = one of several possible Catapult column names
col_map <- list(
  athlete_name         = c("Player Name", "Athlete Name", "Name", "player_name"),
  session_date         = c("Date", "Session Date", "date", "session_date"),
  total_distance_m     = c("Total Distance", "Distance (m)", "total_distance", "Total Distance (m)"),
  high_speed_distance_m= c("High Speed Running Distance", "HSR Distance (m)",
                            "High Speed Distance", "hsr_distance"),
  sprint_distance_m    = c("Sprint Distance", "Sprint Distance (m)", "sprint_distance"),
  player_load          = c("Player Load", "PlayerLoad", "player_load", "Load"),
  session_rpe          = c("RPE", "Session RPE", "rpe", "session_rpe"),
  session_duration_min = c("Duration", "Session Duration (min)", "duration_min", "Duration (min)")
)

find_col <- function(df, candidates) {
  match <- intersect(candidates, names(df))
  if (length(match) == 0) return(NULL)
  match[1]
}

# Build clean data frame
clean <- raw

# Rename columns using the map
for (target in names(col_map)) {
  found <- find_col(raw, col_map[[target]])
  if (!is.null(found)) {
    clean <- clean %>% rename(!!target := !!found)
    cat("  Mapped:", found, "->", target, "\n")
  } else {
    cat("  WARNING: Could not find column for", target,
        "(expected one of:", paste(col_map[[target]], collapse=", "), ")\n")
  }
}

# Keep only our columns (drop everything else)
our_cols <- names(col_map)
available <- intersect(our_cols, names(clean))
clean <- clean %>% select(all_of(available))

# ── Step 3: Clean and validate ───────────────────────────────────────────────
cat("\nCleaning data...\n")

# Standardize athlete name: trim whitespace, title case
if ("athlete_name" %in% names(clean)) {
  clean <- clean %>%
    mutate(athlete_name = str_to_title(str_trim(athlete_name)))
}

# Parse date — handle multiple formats
if ("session_date" %in% names(clean)) {
  clean <- clean %>%
    mutate(session_date = case_when(
      !is.na(parse_date_time(session_date, orders = "mdy", quiet = TRUE)) ~
        format(parse_date_time(session_date, orders = "mdy"), "%Y-%m-%d"),
      !is.na(parse_date_time(session_date, orders = "dmy", quiet = TRUE)) ~
        format(parse_date_time(session_date, orders = "dmy"), "%Y-%m-%d"),
      !is.na(ymd(session_date, quiet = TRUE)) ~
        format(ymd(session_date), "%Y-%m-%d"),
      TRUE ~ NA_character_
    ))
}

# Coerce numeric columns
numeric_cols <- c("total_distance_m","high_speed_distance_m","sprint_distance_m",
                  "player_load","session_rpe","session_duration_min")
for (col in intersect(numeric_cols, names(clean))) {
  clean[[col]] <- suppressWarnings(as.numeric(clean[[col]]))
}

# Drop rows with no athlete name or no date
n_before <- nrow(clean)
clean <- clean %>% filter(!is.na(athlete_name), athlete_name != "", !is.na(session_date))
n_after <- nrow(clean)
if (n_before > n_after) cat("  Dropped", n_before - n_after, "rows with missing name/date\n")

cat("  Rows after cleaning:", nrow(clean), "\n\n")

# ── Step 4: Match athletes to Supabase UUIDs ─────────────────────────────────
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
  stop("Failed to fetch athletes from Supabase.\n",
       "Check your SUPABASE_URL and SUPABASE_KEY.\nError: ", e$message)
})

# Fuzzy name match: try exact first, then last-name match
match_athlete_id <- function(name, db) {
  exact <- db$id[str_to_title(db$name) == name]
  if (length(exact) > 0) return(exact[1])

  # Try last name only
  last <- str_extract(name, "\\S+$")
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
  cat("\n  WARNING:", nrow(unmatched), "athletes could not be matched:\n")
  print(unique(unmatched$athlete_name))
  cat("  These rows will be SKIPPED. Add them to the athletes table in Supabase,\n")
  cat("  or check for name spelling differences between Catapult and Supabase.\n\n")
}

clean <- clean %>% filter(!is.na(athlete_id))
cat("  Matched", nrow(clean), "rows to Supabase athlete IDs\n\n")

# ── Step 5: Build insert payload ─────────────────────────────────────────────
payload <- clean %>%
  select(athlete_id, session_date,
         any_of(c("total_distance_m","high_speed_distance_m","sprint_distance_m",
                   "player_load","session_rpe","session_duration_min"))) %>%
  mutate(
    total_distance_m      = round(coalesce(total_distance_m, 0), 1),
    high_speed_distance_m = round(coalesce(high_speed_distance_m, 0), 1),
    sprint_distance_m     = round(coalesce(sprint_distance_m, 0), 1),
    player_load           = round(coalesce(player_load, 0), 2),
  )

cat("Preview of first 5 rows to be uploaded:\n")
print(head(payload, 5))
cat("\nTotal rows ready to insert:", nrow(payload), "\n\n")

# ── Step 6: Upload to Supabase ───────────────────────────────────────────────
if (DRY_RUN) {
  cat("=============================================================\n")
  cat("  DRY RUN — no data was uploaded.\n")
  cat("  Review the preview above. If it looks correct,\n")
  cat("  set DRY_RUN <- FALSE at the top of this script and re-run.\n")
  cat("=============================================================\n")
} else {
  cat("Uploading to Supabase gps_sessions table...\n")

  # Split into batches of 100 to stay within API limits
  batch_size <- 100
  batches    <- split(payload, ceiling(seq_len(nrow(payload)) / batch_size))
  success    <- 0
  failed     <- 0

  for (i in seq_along(batches)) {
    batch <- batches[[i]]
    tryCatch({
      request(paste0(SUPABASE_URL, "/rest/v1/gps_sessions")) %>%
        req_headers(
          "apikey"        = SUPABASE_KEY,
          "Authorization" = paste("Bearer", SUPABASE_KEY),
          "Content-Type"  = "application/json",
          "Prefer"        = "return=minimal"
        ) %>%
        req_body_json(batch) %>%
        req_perform()
      success <- success + nrow(batch)
      cat("  Batch", i, "of", length(batches), "— inserted", nrow(batch), "rows\n")
    }, error = function(e) {
      failed  <<- failed + nrow(batch)
      cat("  ERROR in batch", i, ":", e$message, "\n")
    })
  }

  cat("\n=============================================================\n")
  cat("  Upload complete.\n")
  cat("  Rows inserted:", success, "\n")
  if (failed > 0) cat("  Rows failed:  ", failed, "\n")
  cat("=============================================================\n")
}
