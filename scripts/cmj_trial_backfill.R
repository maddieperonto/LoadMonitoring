# ═══════════════════════════════════════════════════════════════════════════
# cmj_trial_backfill.R — ONE-TIME backfill of trial-level CMJ data
#
# Re-fetches /trials for every CMJ test since 2026-01-01 (regardless of when
# it was last modified) and upserts all reps into cmj_tests. Safe to re-run:
# upserts are keyed on (vald_test_id, trial_number), so existing rows just
# get refreshed and missing trial rows (2, 3, ...) get inserted.
#
# This is NOT part of the nightly workflow — run manually, once.
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)
library(dplyr)
library(lubridate)
library(stringr)

VALD_CLIENT_ID       <- Sys.getenv("VALD_CLIENT_ID")
VALD_CLIENT_SECRET   <- Sys.getenv("VALD_CLIENT_PASSWORD")
VALD_TENANT_ID       <- Sys.getenv("VALD_DUENDE_ID")
SUPABASE_URL         <- Sys.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY <- Sys.getenv("SUPABASE_SERVICE_KEY")

VALD_TOKEN_URL <- "https://auth.prd.vald.com/oauth/token"
VALD_PROF_BASE <- "https://prd-use-api-externalprofile.valdperformance.com"
VALD_FD_BASE   <- "https://prd-use-api-extforcedecks.valdperformance.com"
VALD_TEAM_ID   <- "f7baafec-7022-4247-8474-1fe92062c787"
BACKFILL_FROM  <- "2026-01-01T00:00:00Z"

`%||%` <- function(a, b) if (!is.null(a)) a else b

cat("[Backfill] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")
cat("[Backfill] Will fetch all CMJ tests modified since", BACKFILL_FROM, "\n")

# ── Get access token ──────────────────────────────────────────────────────
cat("[Backfill] Requesting access token...\n")
token_resp <- request(VALD_TOKEN_URL) |>
  req_method("POST") |>
  req_body_form(
    grant_type    = "client_credentials",
    client_id     = VALD_CLIENT_ID,
    client_secret = VALD_CLIENT_SECRET,
    audience      = "vald-api-external"
  ) |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

if (resp_status(token_resp) != 200) {
  body <- tryCatch(resp_body_string(token_resp), error = function(e) "(empty)")
  stop("[Backfill] Token failed: ", resp_status(token_resp), "\n", body)
}
token_data   <- resp_body_json(token_resp)
access_token <- token_data$access_token
cat("[Backfill] Token obtained. Expires in", token_data$expires_in, "seconds.\n")

# ── Helper: GET ───────────────────────────────────────────────────────────
vald_get <- function(path, query = list(), base_url) {
  req <- request(paste0(base_url, path)) |>
    req_auth_bearer_token(access_token) |>
    req_headers(Accept = "application/json") |>
    req_error(is_error = function(resp) FALSE)
  if (length(query) > 0) req <- req |> req_url_query(!!!query)
  resp <- req_perform(req)
  status <- resp_status(resp)
  if (status == 204) return(NULL)
  if (status != 200) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "(empty body)")
    warning("[Backfill] ", path, " returned ", status, ": ", body)
    return(NULL)
  }
  resp_body_json(resp, simplifyVector = TRUE)
}

# ── Helper: upsert to Supabase (batched) ──────────────────────────────────
sb_upsert <- function(table, rows, on_conflict = NULL, batch_size = 500) {
  if (is.null(rows) || nrow(rows) == 0) { cat("[Supabase] No rows for", table, "\n"); return(invisible(NULL)) }
  n <- nrow(rows)
  n_batches <- ceiling(n / batch_size)
  for (b in seq_len(n_batches)) {
    start <- (b - 1) * batch_size + 1
    end   <- min(b * batch_size, n)
    chunk <- rows[start:end, , drop = FALSE]

    req <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
      req_method("POST") |>
      req_headers(
        apikey         = SUPABASE_SERVICE_KEY,
        Authorization  = paste("Bearer", SUPABASE_SERVICE_KEY),
        "Content-Type" = "application/json",
        Prefer         = "return=minimal,resolution=merge-duplicates"
      )
    if (!is.null(on_conflict)) {
      req <- req |> req_url_query(on_conflict = on_conflict)
    }
    resp <- req |>
      req_body_raw(jsonlite::toJSON(chunk, na = "null", auto_unbox = TRUE), type = "application/json") |>
      req_error(is_error = function(resp) FALSE) |>
      req_perform()
    status <- resp_status(resp)
    if (status %in% c(200, 201)) {
      cat("[Supabase] Upserted batch", b, "/", n_batches, "(", nrow(chunk), "rows ) into", table, "\n")
    } else {
      warning("[Supabase] Upsert batch ", b, " to ", table, " failed: ", status, "\n",
              tryCatch(resp_body_string(resp), error = function(e) "(empty)"))
    }
  }
}

# ── Fetch profiles ─────────────────────────────────────────────────────────
cat("[Backfill] Fetching athlete profiles...\n")
profiles_raw <- vald_get("/profiles", query = list(tenantId = VALD_TENANT_ID), base_url = VALD_PROF_BASE)
if (is.null(profiles_raw) || length(profiles_raw) == 0) {
  profiles_df <- data.frame(profileId = character(), name = character(), stringsAsFactors = FALSE)
} else {
  pdf <- as.data.frame(profiles_raw)
  names(pdf) <- gsub("^profiles\\.", "", names(pdf))
  profiles_df <- pdf |>
    mutate(profileId = as.character(profileId),
           name = paste(as.character(givenName), as.character(familyName))) |>
    select(profileId, name)
}
cat("[Backfill]", nrow(profiles_df), "profiles fetched.\n")

# ── Fetch result definitions ────────────────────────────────────────────────
cat("[Backfill] Fetching ForceDecks result definitions...\n")
rd_raw <- vald_get("/resultdefinitions", query = list(), base_url = VALD_FD_BASE)
rd_lookup <- list()
if (!is.null(rd_raw) && length(rd_raw) > 0) {
  rd_df <- as.data.frame(rd_raw)
  if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
  names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))
  for (i in seq_len(nrow(rd_df))) {
    rd_lookup[[as.character(rd_df$resultId[i])]] <- tolower(as.character(rd_df$resultName[i]))
  }
}
cat("[Backfill]", length(rd_lookup), "result definitions loaded.\n")

# ── Fetch ALL ForceDecks tests since BACKFILL_FROM ─────────────────────────
cat("[Backfill] Fetching all ForceDecks tests since", BACKFILL_FROM, "...\n")
all_fd_rows <- list()
current_from <- BACKFILL_FROM
repeat {
  fd_page <- vald_get("/tests", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = current_from), base_url = VALD_FD_BASE)
  if (is.null(fd_page) || length(fd_page) == 0) break
  page_df <- as.data.frame(fd_page)
  names(page_df) <- gsub("^tests\\.", "", names(page_df))
  all_fd_rows <- c(all_fd_rows, list(page_df))
  cat("[Backfill] Fetched page of", nrow(page_df), "tests. Total so far:", sum(sapply(all_fd_rows, nrow)), "\n")
  if (nrow(page_df) < 50) break
  current_from <- page_df$modifiedDateUtc[nrow(page_df)]
  Sys.sleep(0.25)
}
fd_raw <- if (length(all_fd_rows) > 0) do.call(rbind, all_fd_rows) else NULL
cat("[Backfill] Total ForceDecks tests fetched:", if (!is.null(fd_raw)) nrow(fd_raw) else 0, "\n")

if (is.null(fd_raw) || nrow(fd_raw) == 0) {
  cat("[Backfill] No tests found. Exiting.\n")
} else {

  fd_df <- fd_raw |>
    left_join(profiles_df, by = c("profileId" = "profileId")) |>
    mutate(
      athlete_name    = coalesce(name, as.character(profileId)),
      test_date       = as.character(as.Date(recordedDateUtc)),
      vald_test_id    = as.character(testId),
      vald_profile_id = as.character(profileId)
    ) |>
    filter(!is.na(test_date))

  CMJ_TYPES <- c("CMJ", "CMJA", "CMJL", "SJ", "SJA", "DJ", "DJA", "IMTP", "HOP")
  is_cmj <- sapply(toupper(fd_df$testType), function(ttype) {
    any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed = TRUE)))
  })
  fd_df <- fd_df[is_cmj, , drop = FALSE]
  cat("[Backfill]", nrow(fd_df), "CMJ-type tests to process.\n")

  # ── Helper: extract a metric from ONE trial's results data frame ─────────
  get_metric_from_trial <- function(results_list, keywords, limb_filter = NULL) {
    res <- results_list
    if (is.null(res) || !is.data.frame(res) || nrow(res) == 0) return(NA_real_)
    for (j in seq_len(nrow(res))) {
      rid   <- as.character(res$resultId[j])
      rname <- tolower(rd_lookup[[rid]] %||% "")
      if (!any(sapply(keywords, function(k) grepl(k, rname, fixed = TRUE)))) next
      if (!is.null(limb_filter)) {
        limb_val <- if ("limb" %in% names(res)) tolower(res$limb[j]) else ""
        if (!grepl(tolower(limb_filter), limb_val, fixed = TRUE)) next
      }
      return(as.numeric(res$value[j]))
    }
    NA_real_
  }

  # ── Fetch trials for every test (rate-limited) and build trial rows ───────
  n_tests <- nrow(fd_df)
  cat("[Backfill] Fetching trials for", n_tests, "tests (this will take a while)...\n")

  all_trial_rows <- vector("list", n_tests)

  for (i in seq_len(n_tests)) {
    tid <- fd_df$testId[i]
    tr <- vald_get(
      paste0("/v2019q3/teams/", VALD_TEAM_ID, "/tests/", tid, "/trials"),
      query    = list(),
      base_url = VALD_FD_BASE
    )
    Sys.sleep(0.25)

    if (i %% 25 == 0 || i == n_tests) {
      cat("[Backfill] Processed", i, "/", n_tests, "tests...\n")
    }

    if (is.null(tr) || !is.data.frame(tr) || nrow(tr) == 0) next

    per_trial <- lapply(seq_len(nrow(tr)), function(t) {
      res <- tr$results[[t]]
      data.frame(
        vald_test_id                       = as.character(fd_df$testId[i]),
        vald_profile_id                    = as.character(fd_df$profileId[i]),
        athlete_name                       = fd_df$athlete_name[i],
        test_date                          = fd_df$test_date[i],
        trial_number                       = t,
        jump_height_cm                     = get_metric_from_trial(res, c("jump height (flight time)")),
        peak_force_n                       = get_metric_from_trial(res, c("peak force")),
        peak_power_w                       = get_metric_from_trial(res, c("peak power / bm", "peak power")),
        rsi_modified                       = get_metric_from_trial(res, c("rsi-modified", "rsi modified", "reactive strength")),
        concentric_impulse_ns              = get_metric_from_trial(res, c("concentric impulse")),
        eccentric_decel_impulse_ns         = get_metric_from_trial(res, c("eccentric decel")),
        eccentric_decel_rfd_bm             = get_metric_from_trial(res, c("eccentric deceleration rfd / bm")),
        eccentric_peak_power_bm            = get_metric_from_trial(res, c("eccentric peak power / bm")),
        flight_time_contraction_time       = get_metric_from_trial(res, c("flight time:contraction time", "flighttime:contraction time")),
        eccentric_peak_force_asymmetry_pct = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "asym"),
        eccentric_peak_force_left          = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "left"),
        eccentric_peak_force_right         = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "right"),
        stringsAsFactors = FALSE
      )
    })

    all_trial_rows[[i]] <- do.call(rbind, per_trial)
  }

  cat("[Backfill] Trial fetching complete.\n")

  cmj_rows <- do.call(rbind, Filter(Negate(is.null), all_trial_rows))
  if (is.null(cmj_rows) || nrow(cmj_rows) == 0) {
    cat("[Backfill] No trial rows produced. Exiting.\n")
  } else {
    cmj_rows <- cmj_rows |>
      mutate(across(where(is.numeric), ~ ifelse(is.nan(.), NA_real_, .))) |>
      filter(!is.na(test_date))

    cat("[Backfill]", nrow(cmj_rows), "total trial rows to upsert across", n_distinct(cmj_rows$vald_test_id), "tests.\n")
    sb_upsert("cmj_tests", cmj_rows, on_conflict = "vald_test_id,trial_number")
  }
}

cat("[Backfill] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")
