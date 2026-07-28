# ═══════════════════════════════════════════════════════════════════════════
# catapult_recheck_backfill.R — Re-pull /stats for all existing activities
# and store fresh results in a SEPARATE table for comparison.
# Does NOT touch catapult_sessions.
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)
library(dplyr)

CATAPULT_BASE_URL    <- Sys.getenv("CATAPULT_BASE_URL")
CATAPULT_API_TOKEN   <- Sys.getenv("CATAPULT_API_TOKEN")
SUPABASE_URL         <- Sys.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY <- Sys.getenv("SUPABASE_SERVICE_KEY")

cat("[Recheck] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")

headers <- c(
  Authorization = paste("Bearer", CATAPULT_API_TOKEN),
  "Content-Type" = "application/json"
)

# ── Get distinct activity IDs already in catapult_sessions ────────────────
cat("[Recheck] Fetching distinct activity IDs from catapult_sessions...\n")
act_resp <- request(paste0(SUPABASE_URL, "/rest/v1/catapult_sessions")) |>
  req_headers(apikey = SUPABASE_SERVICE_KEY, Authorization = paste("Bearer", SUPABASE_SERVICE_KEY)) |>
  req_url_query(select = "catapult_activity_id") |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

all_rows <- resp_body_json(act_resp, simplifyVector = TRUE)
activity_ids <- unique(all_rows$catapult_activity_id)
cat("[Recheck]", length(activity_ids), "distinct activities to recheck.\n")

# ── Loop through each activity and re-pull fresh stats ─────────────────────
recheck_rows <- list()

for (i in seq_along(activity_ids)) {
  aid <- activity_ids[i]
  cat("[Recheck] (", i, "/", length(activity_ids), ")", aid, "\n")

  act_detail_resp <- request(paste0(CATAPULT_BASE_URL, "/activities/", aid)) |>
    req_headers(!!!headers) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()

  if (resp_status(act_detail_resp) != 200) {
    cat("  Activity fetch failed:", resp_status(act_detail_resp), "\n")
    Sys.sleep(0.3)
    next
  }
  activity <- resp_body_json(act_detail_resp)

  stats_resp <- request(paste0(CATAPULT_BASE_URL, "/stats")) |>
    req_method("POST") |>
    req_headers(!!!headers) |>
    req_body_json(list(
      filters = list(list(name = "activity_id", comparison = "=", values = list(aid))),
      parameters = list(
        "total_player_load", "total_distance", "total_duration",
        "max_vel",
        "gen2_acceleration_band6_total_effort_count",
        "gen2_acceleration_band7_total_effort_count",
        "gen2_acceleration_band8_total_effort_count",
        "gen2_acceleration_band1_total_effort_count",
        "gen2_acceleration_band2_total_effort_count",
        "gen2_acceleration_band3_total_effort_count"
      ),
      group_by = list("athlete")
    )) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()

  if (resp_status(stats_resp) != 200) {
    cat("  Stats fetch failed:", resp_status(stats_resp), "\n")
    Sys.sleep(0.3)
    next
  }
  stats <- resp_body_json(stats_resp, simplifyVector = TRUE)

  if (is.null(stats) || length(stats) == 0 || nrow(stats) == 0) {
    Sys.sleep(0.3)
    next
  }

  rows <- data.frame(
    catapult_activity_id = aid,
    catapult_athlete_id   = stats$athlete_id,
    athlete_name          = stats$athlete_name,
    activity_name         = activity$name %||% NA,
    session_date          = stats$date %||% NA,
    total_player_load     = as.numeric(stats$total_player_load),
    total_distance        = as.numeric(stats$total_distance),
    total_duration        = as.numeric(stats$total_duration),
    max_velocity          = as.numeric(stats$max_vel),
    accel_total_efforts   = (as.numeric(stats$gen2_acceleration_band6_total_effort_count %||% 0) +
                               as.numeric(stats$gen2_acceleration_band7_total_effort_count %||% 0) +
                               as.numeric(stats$gen2_acceleration_band8_total_effort_count %||% 0)),
    decel_total_efforts   = (as.numeric(stats$gen2_acceleration_band1_total_effort_count %||% 0) +
                               as.numeric(stats$gen2_acceleration_band2_total_effort_count %||% 0) +
                               as.numeric(stats$gen2_acceleration_band3_total_effort_count %||% 0)),
    rechecked_at          = as.character(Sys.time()),
    stringsAsFactors = FALSE
  )

  recheck_rows[[length(recheck_rows) + 1]] <- rows
  Sys.sleep(0.3)
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

all_recheck <- do.call(rbind, recheck_rows)
cat("[Recheck] Total rows to insert:", nrow(all_recheck), "\n")

# ── Insert into new table (plain insert, no upsert needed — fresh table) ──
chunk_size <- 500
for (start in seq(1, nrow(all_recheck), by = chunk_size)) {
  end <- min(start + chunk_size - 1, nrow(all_recheck))
  chunk <- all_recheck[start:end, ]

  insert_resp <- request(paste0(SUPABASE_URL, "/rest/v1/catapult_sessions_recheck")) |>
    req_method("POST") |>
    req_headers(
      apikey = SUPABASE_SERVICE_KEY,
      Authorization = paste("Bearer", SUPABASE_SERVICE_KEY),
      "Content-Type" = "application/json",
      Prefer = "return=minimal"
    ) |>
    req_body_raw(jsonlite::toJSON(chunk, na = "null", auto_unbox = TRUE), type = "application/json") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()

  cat("[Recheck] Inserted rows", start, "-", end, "status:", resp_status(insert_resp), "\n")
}

cat("[Recheck] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")
