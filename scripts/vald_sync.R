# ═══════════════════════════════════════════════════════════════════════════
# vald_sync.R — Nightly VALD sync for ForceDecks and NordBord
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
VALD_NORD_BASE <- "https://prd-use-api-externalnordbord.valdperformance.com"
VALD_TEAM_ID   <- "f7baafec-7022-4247-8474-1fe92062c787"
LOOKBACK_DAYS  <- 7
`%||%` <- function(a, b) if (!is.null(a)) a else b

cat("[VALD Sync] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")

# ── Get access token ──────────────────────────────────────────────────────
cat("[VALD Sync] Requesting access token...\n")
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
  stop("[VALD Sync] Token failed: ", resp_status(token_resp), "\n", body)
}
token_data   <- resp_body_json(token_resp)
access_token <- token_data$access_token
cat("[VALD Sync] Token obtained. Expires in", token_data$expires_in, "seconds.\n")

# ── Helper: GET ───────────────────────────────────────────────────────────
vald_get <- function(path, query = list(), base_url) {
  req <- request(paste0(base_url, path)) |>
    req_auth_bearer_token(access_token) |>
    req_headers(Accept = "application/json") |>
    req_error(is_error = function(resp) FALSE)
  if (length(query) > 0) req <- req |> req_url_query(!!!query)
  resp <- req_perform(req)
  status <- resp_status(resp)
  if (status == 204) { cat("[VALD Sync] 204 No Content for", path, "\n"); return(NULL) }
  if (status != 200) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "(empty body)")
    warning("[VALD Sync] ", path, " returned ", status, ": ", body)
    return(NULL)
  }
  resp_body_json(resp, simplifyVector = TRUE)
}

# ── Helper: upsert to Supabase ────────────────────────────────────────────
sb_upsert <- function(table, rows, on_conflict = NULL) {
  if (is.null(rows) || nrow(rows) == 0) { cat("[Supabase] No rows for", table, "\n"); return(invisible(NULL)) }
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
    req_body_raw(jsonlite::toJSON(rows, na = "null", auto_unbox = TRUE), type = "application/json") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (status %in% c(200, 201)) cat("[Supabase] Upserted", nrow(rows), "rows into", table, "\n")
  else warning("[Supabase] Upsert to ", table, " failed: ", status, "\n",
               tryCatch(resp_body_string(resp), error = function(e) "(empty)"))
}

# ── Helper: last sync date ────────────────────────────────────────────────
get_last_sync <- function(table, date_col) {
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
    req_headers(apikey = SUPABASE_SERVICE_KEY, Authorization = paste("Bearer", SUPABASE_SERVICE_KEY)) |>
    req_url_query(select = date_col, order = paste0(date_col, ".desc"), limit = "1") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  if (resp_status(resp) != 200) return(NULL)
  rows <- resp_body_json(resp, simplifyVector = TRUE)
  if (is.null(rows) || length(rows) == 0) return(NULL)
  as.POSIXct(rows[[date_col]][1], format = "%Y-%m-%d", tz = "UTC")
}

# ── Step 2: Fetch profiles ────────────────────────────────────────────────
cat("[VALD Sync] Fetching athlete profiles...\n")
profiles_raw <- vald_get("/profiles", query = list(tenantId = VALD_TENANT_ID), base_url = VALD_PROF_BASE)
if (is.null(profiles_raw) || length(profiles_raw) == 0) {
  cat("[VALD Sync] No profiles returned.\n")
  profiles_df <- data.frame(profileId = character(), name = character(), stringsAsFactors = FALSE)
} else {
  pdf <- as.data.frame(profiles_raw)
  names(pdf) <- gsub("^profiles\\.", "", names(pdf))
  profiles_df <- pdf |>
    mutate(profileId = as.character(profileId),
           name = paste(as.character(givenName), as.character(familyName))) |>
    select(profileId, name)
  cat("[VALD Sync]", nrow(profiles_df), "profiles fetched.\n")
}

# ── Step 3: ForceDecks result definitions ─────────────────────────────────
cat("[VALD Sync] Fetching ForceDecks result definitions...\n")
rd_raw <- vald_get("/resultdefinitions", query = list(), base_url = VALD_FD_BASE)
rd_lookup <- list()
if (!is.null(rd_raw) && length(rd_raw) > 0) {
  rd_df <- as.data.frame(rd_raw)
  if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
  names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))
  for (i in seq_len(nrow(rd_df))) {
    rd_lookup[[as.character(rd_df$resultId[i])]] <- tolower(as.character(rd_df$resultName[i]))
  }
  cat("[VALD Sync]", length(rd_lookup), "result definitions loaded.\n")
}

# ── Step 4: ForceDecks tests ──────────────────────────────────────────────
cat("[VALD Sync] Fetching ForceDecks tests...\n")
last_cmj <- get_last_sync("cmj_tests", "test_date")
from_utc <- format(
  if (is.null(last_cmj)) as.POSIXct("2026-01-01T00:00:00Z", tz = "UTC") else last_cmj - days(1),
  "%Y-%m-%dT%H:%M:%SZ"
)
cat("[VALD Sync] ForceDecks from:", from_utc, "\n")

all_fd_rows <- list()
current_from <- from_utc
repeat {
  fd_page <- vald_get("/tests", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = current_from), base_url = VALD_FD_BASE)
  if (is.null(fd_page) || length(fd_page) == 0) break
  page_df <- as.data.frame(fd_page)
  names(page_df) <- gsub("^tests\\.", "", names(page_df))
  all_fd_rows <- c(all_fd_rows, list(page_df))
  cat("[VALD Sync] Fetched page of", nrow(page_df), "tests. Total so far:", sum(sapply(all_fd_rows, nrow)), "\n")
  if (nrow(page_df) < 50) break
  current_from <- page_df$modifiedDateUtc[nrow(page_df)]
  Sys.sleep(0.25)
}
fd_raw <- if (length(all_fd_rows) > 0) do.call(rbind, all_fd_rows) else NULL
cat("[VALD Sync] Total ForceDecks tests fetched:", if (!is.null(fd_raw)) nrow(fd_raw) else 0, "\n")

if (!is.null(fd_raw) && nrow(fd_raw) > 0) {
  fdf <- fd_raw
  cat("[VALD Sync] ForceDecks columns:", paste(names(fdf), collapse = ", "), "\n")
  cat("[VALD Sync] Test types in batch:", paste(names(table(fdf$testType)), collapse = ", "), "\n")

  fd_df <- tryCatch({
    fdf |>
      left_join(profiles_df, by = c("profileId" = "profileId")) |>
      mutate(
        athlete_name    = coalesce(name, as.character(profileId)),
        test_date       = as.character(as.Date(recordedDateUtc)),
        vald_test_id    = as.character(testId),
        vald_profile_id = as.character(profileId)
      )
  }, error = function(e) { cat("[VALD Sync] Parse error FD:", conditionMessage(e), "\n"); NULL })

  if (!is.null(fd_df) && nrow(fd_df) > 0) {
    cat("[VALD Sync] Fetching trials for", nrow(fd_df), "tests...\n")

    CMJ_TYPES <- c("CMJ", "CMJA", "CMJL", "SJ", "SJA", "DJ", "DJA", "IMTP", "HOP")

    trial_data <- lapply(seq_len(nrow(fd_df)), function(i) {
      tid   <- fd_df$testId[i]
      ttype <- toupper(fd_df$testType[i])
      if (!any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed = TRUE)))) return(NULL)
      tr <- vald_get(
        paste0("/v2019q3/teams/", VALD_TEAM_ID, "/tests/", tid, "/trials"),
        query    = list(),
        base_url = VALD_FD_BASE
      )
      Sys.sleep(0.25)
      tr
    })
    cat("[VALD Sync] Trials fetched.\n")

    # ── Helper: extract a metric from ONE trial's results data frame ────────
    get_metric_from_trial <- function(results_list, keywords, limb_filter = NULL) {
      if (is.null(results_list) || !is.data.frame(results_list)) return(NA_real_)
      res <- results_list
      if (!is.data.frame(res) || nrow(res) == 0) return(NA_real_)
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

    # ── Build one row per trial ─────────────────────────────────────────────
    cmj_trial_rows <- lapply(seq_len(nrow(fd_df)), function(i) {
      ttype <- toupper(fd_df$testType[i])
      if (!any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed = TRUE)))) return(NULL)

      trials <- trial_data[[i]]
      if (is.null(trials) || !is.data.frame(trials) || nrow(trials) == 0) return(NULL)

      per_trial <- lapply(seq_len(nrow(trials)), function(t) {
        res <- trials$results[[t]]  # the results data frame for this one trial

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

      do.call(rbind, per_trial)
    })

    cmj_rows <- do.call(rbind, Filter(Negate(is.null), cmj_trial_rows)) |>
      mutate(across(where(is.numeric), ~ ifelse(is.nan(.), NA_real_, .))) |>
      filter(!is.na(test_date))

    cat("[VALD Sync]", nrow(cmj_rows), "CMJ trial rows to upsert.\n")
    sb_upsert("cmj_tests", cmj_rows, on_conflict = "vald_test_id,trial_number")
  }
} else {
  cat("[VALD Sync] No new ForceDecks tests.\n")
}

# ── Step 5: NordBord ──────────────────────────────────────────────────────
cat("[VALD Sync] Fetching NordBord tests...\n")
last_nord   <- get_last_sync("nordbord_tests", "test_date")
from_utc_nb <- format(
  if (is.null(last_nord)) as.POSIXct("2026-01-01T00:00:00Z", tz = "UTC") else last_nord - days(1),
  "%Y-%m-%dT%H:%M:%SZ"
)
cat("[VALD Sync] NordBord from:", from_utc_nb, "\n")

all_nb_rows <- list()
current_from_nb <- from_utc_nb
repeat {
  nb_page <- vald_get("/tests/v2", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = current_from_nb), base_url = VALD_NORD_BASE)
  if (is.null(nb_page) || length(nb_page) == 0) break
  page_df_nb <- as.data.frame(nb_page)
  names(page_df_nb) <- gsub("^tests\\.", "", names(page_df_nb))
  all_nb_rows <- c(all_nb_rows, list(page_df_nb))
  cat("[VALD Sync] Fetched NordBord page of", nrow(page_df_nb), "tests. Total:", sum(sapply(all_nb_rows, nrow)), "\n")
  if (nrow(page_df_nb) < 50) break
  current_from_nb <- page_df_nb$modifiedDateUtc[nrow(page_df_nb)]
  Sys.sleep(0.5)
}
nb_raw <- if (length(all_nb_rows) > 0) do.call(rbind, all_nb_rows) else NULL
cat("[VALD Sync] Total NordBord tests fetched:", if (!is.null(nb_raw)) nrow(nb_raw) else 0, "\n")

if (!is.null(nb_raw) && nrow(nb_raw) > 0) {
  nb_df <- tryCatch({
    nb_raw |>
      left_join(profiles_df, by = c("profileId" = "profileId")) |>
      mutate(
        athlete_name    = coalesce(name, as.character(profileId)),
        test_date       = as.character(as.Date(testDateUtc)),
        vald_test_id    = as.character(testId),
        vald_profile_id = as.character(profileId)
      )
  }, error = function(e) { cat("[VALD Sync] Parse error NB:", conditionMessage(e), "\n"); NULL })

  if (!is.null(nb_df) && nrow(nb_df) > 0) {
    nord_rows <- nb_df |>
      mutate(
        left_peak_force_n  = as.numeric(leftMaxForce),
        right_peak_force_n = as.numeric(rightMaxForce),
        lsi_pct = case_when(
          !is.na(left_peak_force_n) & !is.na(right_peak_force_n) &
            pmax(left_peak_force_n, right_peak_force_n) > 0 ~
            round(pmin(left_peak_force_n, right_peak_force_n) /
                    pmax(left_peak_force_n, right_peak_force_n) * 100, 1),
          TRUE ~ NA_real_
        ),
        bw_ratio = NA_real_
      ) |>
      select(vald_test_id, vald_profile_id, athlete_name, test_date,
             left_peak_force_n, right_peak_force_n, lsi_pct, bw_ratio) |>
      filter(!is.na(test_date)) |>
      group_by(vald_test_id) |>
      slice_max(order_by = coalesce(left_peak_force_n, 0), n = 1, with_ties = FALSE) |>
      ungroup()

    cat("[VALD Sync]", nrow(nord_rows), "NordBord rows to upsert.\n")
    sb_upsert("nordbord_tests", nord_rows)
  }
} else {
  cat("[VALD Sync] No new NordBord tests.\n")
}

cat("[VALD Sync] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")