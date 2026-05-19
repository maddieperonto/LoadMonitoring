# ============================================================================
# nordbord_to_supabase.R
# ----------------------------------------------------------------------------
# PURPOSE:
#   Reads a raw NordBord CSV export, maps columns, computes LSI and BW Ratio
#   from raw left/right force values, matches athletes by name, and inserts
#   new test results into the Supabase nordbord_tests table.
#
# WHEN TO RUN THIS:
#   After each NordBord testing block (typically every 2–4 weeks).
#   You do NOT need this during testing — seed_data.sql has simulated data.
#
# REQUIREMENTS:
#   install.packages(c("httr2", "readr", "dplyr", "stringr", "lubridate"))
#
# NORDBORD EXPORT STEPS:
#   1. Open the Vald Performance Hub (nordbord.valdperformance.com)
#   2. Go to Results → NordBord → select your testing session
#   3. Export → CSV → save the file
#   4. Set NORDBORD_CSV_PATH below
#
# KEY COMPUTED METRICS (calculated here, not stored raw in export):
#   LSI %    = LEAST(left, right) / GREATEST(left, right) × 100
#   BW Ratio = GREATEST(left, right) / athlete_bodyweight_in_newtons
#              where bodyweight_N = weight_lbs × 4.44822
#
# FLAG THRESHOLDS (applied automatically by the dashboard JS):
#   LSI < 90%   → RED: Hamstring Asymmetry — RTP Risk
#   LSI 90–95%  → AMBER: Monitor Hamstring Symmetry
#   Force < 200N either limb → RED: Absolute Strength Deficit
#   BW Ratio < 0.45 → AMBER: Below Strength Threshold
# ============================================================================

library(httr2)
library(readr)
library(dplyr)
library(stringr)
library(lubridate)

# ============================================================================
# CONFIG — edit these before running
# ============================================================================
NORDBORD_CSV_PATH <- "path/to/your/nordbord_export.csv"   # ← update this
SUPABASE_URL      <- "https://fyhgvxfrwbwuqxllodip.supabase.co"                   # ← same as supabase_client.js
SUPABASE_KEY      <- "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U"              # ← same as supabase_client.js
DRY_RUN           <- TRUE   # TRUE = preview only. Set FALSE to actually insert.
# ============================================================================

cat("=============================================================\n")
cat("  UF S&C — NordBord Import\n")
cat("=============================================================\n")
cat("CSV path:", NORDBORD_CSV_PATH, "\n")
cat("Dry run: ", DRY_RUN, "\n\n")

# ── Step 1: Load CSV ─────────────────────────────────────────────────────────
if (!file.exists(NORDBORD_CSV_PATH)) {
  stop("CSV file not found at: ", NORDBORD_CSV_PATH)
}

raw <- read_csv(NORDBORD_CSV_PATH, show_col_types = FALSE)
cat("Loaded CSV:", nrow(raw), "rows,", ncol(raw), "columns\n")
cat("Columns found:", paste(names(raw), collapse = ", "), "\n\n")

# ── Step 2: Map NordBord column names ────────────────────────────────────────
# NordBord / Vald Hub exports. Covers common naming variations.
col_map <- list(
  athlete_name       = c("Athlete", "Name", "Player", "Athlete Name", "athlete_name"),
  test_date          = c("Date", "Test Date", "Session Date", "date", "test_date"),
  left_peak_force_n  = c("Left Peak Force (N)", "Left Force (N)", "Left Max Force (N)",
                          "Left", "left_peak_force", "Left Peak (N)", "Left Force"),
  right_peak_force_n = c("Right Peak Force (N)", "Right Force (N)", "Right Max Force (N)",
                          "Right", "right_peak_force", "Right Peak (N)", "Right Force"),
  # Optional: some exports include these pre-computed
  lsi_pct            = c("LSI (%)", "LSI", "Limb Symmetry Index", "lsi_pct"),
  bw_ratio           = c("BW Ratio", "Body Weight Ratio", "Force:BW", "bw_ratio")
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
    if (target %in% c("left_peak_force_n","right_peak_force_n")) {
      stop("REQUIRED column '", target, "' not found.\n",
           "Tried: ", paste(col_map[[target]], collapse=", "), "\n",
           "Check your NordBord export format.")
    }
    cat("  INFO: Optional column not found for", target, "(will be computed)\n")
  }
}

our_cols  <- names(col_map)
available <- intersect(our_cols, names(clean))
clean     <- clean %>% select(all_of(available))

# ── Step 3: Clean ────────────────────────────────────────────────────────────
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

numeric_cols <- c("left_peak_force_n","right_peak_force_n","lsi_pct","bw_ratio")
for (col in intersect(numeric_cols, names(clean))) {
  clean[[col]] <- suppressWarnings(as.numeric(clean[[col]]))
}

n_before <- nrow(clean)
clean <- clean %>%
  filter(!is.na(athlete_name), athlete_name != "",
         !is.na(test_date),
         !is.na(left_peak_force_n),  left_peak_force_n > 0,
         !is.na(right_peak_force_n), right_peak_force_n > 0)
cat("  Dropped", n_before - nrow(clean), "invalid rows\n")
cat("  Rows after cleaning:", nrow(clean), "\n\n")

# ── Step 4: Match athletes to Supabase (need weight for BW Ratio) ────────────
cat("Fetching athlete list from Supabase (including weight)...\n")

tryCatch({
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/athletes")) %>%
    req_headers(
      "apikey"        = SUPABASE_KEY,
      "Authorization" = paste("Bearer", SUPABASE_KEY)
    ) %>%
    req_url_query(select = "id,name,weight_lbs") %>%
    req_perform()
  athletes_db <- resp %>% resp_body_json(simplifyVector = TRUE) %>% as.data.frame()
  cat("  Found", nrow(athletes_db), "athletes\n")
}, error = function(e) {
  stop("Failed to fetch athletes: ", e$message)
})

match_athlete <- function(name, db) {
  exact <- db[str_to_title(db$name) == name, ]
  if (nrow(exact) > 0) return(exact[1, c("id","weight_lbs")])
  last  <- str_extract(name, "\\S+$")
  last_match <- db[str_detect(str_to_title(db$name), fixed(last)), ]
  if (nrow(last_match) == 1) return(last_match[1, c("id","weight_lbs")])
  return(data.frame(id = NA_character_, weight_lbs = NA_real_))
}

matched <- clean %>%
  rowwise() %>%
  mutate(
    match_result = list(match_athlete(athlete_name, athletes_db)),
    athlete_id   = match_result$id,
    weight_lbs   = match_result$weight_lbs
  ) %>%
  ungroup() %>%
  select(-match_result)

unmatched <- matched %>% filter(is.na(athlete_id))
if (nrow(unmatched) > 0) {
  cat("\n  WARNING:", nrow(unmatched), "unmatched athletes (will be skipped):\n")
  print(unique(unmatched$athlete_name))
}

clean <- matched %>% filter(!is.na(athlete_id))
cat("  Matched", nrow(clean), "rows\n\n")

# ── Step 5: Compute LSI and BW Ratio ─────────────────────────────────────────
cat("Computing LSI and BW Ratio...\n")

clean <- clean %>%
  mutate(
    # LSI: weaker limb / stronger limb × 100
    lsi_pct  = if_else(
      !is.na(lsi_pct), lsi_pct,   # use export value if already present
      round(pmin(left_peak_force_n, right_peak_force_n) /
              pmax(left_peak_force_n, right_peak_force_n) * 100, 2)
    ),

    # BW Ratio: stronger limb peak force / bodyweight in Newtons
    bw_ratio = if_else(
      !is.na(bw_ratio), bw_ratio,   # use export value if already present
      if_else(
        !is.na(weight_lbs) & weight_lbs > 0,
        round(pmax(left_peak_force_n, right_peak_force_n) / (weight_lbs * 4.44822), 4),
        NA_real_
      )
    )
  )

# Report flagged athletes
flagged_lsi   <- clean %>% filter(lsi_pct < 90)
flagged_force <- clean %>% filter(left_peak_force_n < 200 | right_peak_force_n < 200)
flagged_bw    <- clean %>% filter(!is.na(bw_ratio), bw_ratio < 0.45)

cat("  Computed LSI and BW Ratio for all matched athletes\n")
if (nrow(flagged_lsi) > 0) {
  cat("  🔴 LSI < 90% (RTP Risk):", paste(flagged_lsi$athlete_name, collapse=", "), "\n")
}
if (nrow(flagged_force) > 0) {
  cat("  🔴 Absolute Force < 200N:", paste(flagged_force$athlete_name, collapse=", "), "\n")
}
if (nrow(flagged_bw) > 0) {
  cat("  🟡 BW Ratio < 0.45:", paste(flagged_bw$athlete_name, collapse=", "), "\n")
}
cat("\n")

# ── Step 6: Deduplicate ───────────────────────────────────────────────────────
cat("Checking for duplicates already in Supabase...\n")

tryCatch({
  existing_resp <- request(paste0(SUPABASE_URL, "/rest/v1/nordbord_tests")) %>%
    req_headers("apikey" = SUPABASE_KEY, "Authorization" = paste("Bearer", SUPABASE_KEY)) %>%
    req_url_query(select = "athlete_id,test_date") %>%
    req_perform()
  existing <- existing_resp %>% resp_body_json(simplifyVector = TRUE) %>% as.data.frame()

  if (nrow(existing) > 0) {
    existing_keys <- paste(existing$athlete_id, existing$test_date, sep="_")
    new_keys      <- paste(clean$athlete_id, clean$test_date, sep="_")
    dupes         <- sum(new_keys %in% existing_keys)
    clean         <- clean[!new_keys %in% existing_keys, ]
    if (dupes > 0) cat("  Skipped", dupes, "duplicate rows\n")
  }
  cat("  Rows to insert:", nrow(clean), "\n\n")
}, error = function(e) {
  cat("  Could not check duplicates (proceeding):", e$message, "\n\n")
})

# ── Step 7: Build payload ─────────────────────────────────────────────────────
payload <- clean %>%
  select(athlete_id, test_date,
         left_peak_force_n, right_peak_force_n, lsi_pct, bw_ratio) %>%
  mutate(
    left_peak_force_n  = round(left_peak_force_n, 1),
    right_peak_force_n = round(right_peak_force_n, 1),
    lsi_pct            = round(lsi_pct, 2),
    bw_ratio           = round(bw_ratio, 4)
  )

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
  cat("Uploading to Supabase nordbord_tests table...\n")
  batch_size <- 100
  batches    <- split(payload, ceiling(seq_len(nrow(payload)) / batch_size))
  success    <- 0
  failed     <- 0

  for (i in seq_along(batches)) {
    tryCatch({
      request(paste0(SUPABASE_URL, "/rest/v1/nordbord_tests")) %>%
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
