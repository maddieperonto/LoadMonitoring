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
sb_upsert <- function(table, rows) {
  if (is.null(rows) || nrow(rows) == 0) { cat("[Supabase] No rows for", table, "\n"); return(invisible(NULL)) }
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
    req_method("POST") |>
    req_headers(
      apikey         = SUPABASE_SERVICE_KEY,
      Authorization  = paste("Bearer", SUPABASE_SERVICE_KEY),
      "Content-Type" = "application/json",
      Prefer         = "return=minimal,resolution=merge-duplicates"
    ) |>
    req_body_raw(jsonlite::toJSON(rows, na="null", auto_unbox=TRUE), type="application/json") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (status %in% c(200, 201)) cat("[Supabase] Upserted", nrow(rows), "rows into", table, "\n")
  else warning("[Supabase] Upsert to ", table, " failed: ", status, "\n", tryCatch(resp_body_string(resp), error=function(e)"(empty)"))
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
  cat("[VALD Sync] No profiles — will use profileId as athlete name.\n")
  profiles_df <- data.frame(profileId = character(), name = character(), stringsAsFactors = FALSE)
} else {
  pdf <- as.data.frame(profiles_raw)
  names(pdf) <- gsub("^profiles\\.", "", names(pdf))
  profiles_df <- pdf |>
    mutate(profileId = as.character(profileId), name = paste(as.character(givenName), as.character(familyName))) |>
    select(profileId, name)
  cat("[VALD Sync]", nrow(profiles_df), "profiles fetched.\n")
}

# ── Step 3: ForceDecks ────────────────────────────────────────────────────
cat("[VALD Sync] Fetching ForceDecks result definitions...\n")
rd_raw <- vald_get("/resultdefinitions", query = list(), base_url = VALD_FD_BASE)
rd_lookup <- list()
if (!is.null(rd_raw) && length(rd_raw) > 0) {
  rd_df <- as.data.frame(rd_raw)
  if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
  names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))
  for (i in seq_len(nrow(rd_df))) {
    rid <- as.character(rd_df$resultId[i])
    rname <- tolower(as.character(rd_df$resultName[i]))
    rd_lookup[[rid]] <- rname
  }
  cat("[VALD Sync]", length(rd_lookup), "result definitions loaded.\n")
}

get_result_val <- function(params, target_strings) {
  if (is.null(params) || length(params) == 0) return(NA_real_)
  if (is.data.frame(params)) {
    for (rid in as.character(params$resultId)) {
      name <- tolower(rd_lookup[[rid]] %||% "")
      if (any(sapply(target_strings, function(t) grepl(t, name, fixed=TRUE)))) {
        idx <- which(as.character(params$resultId) == rid)[1]
        return(as.numeric(params$value[idx]))
      }
    }
  }
  NA_real_
}
`%||%` <- function(a, b) if (!is.null(a)) a else b

cat("[VALD Sync] Fetching ForceDecks tests...\n")
last_cmj  <- get_last_sync("cmj_tests", "test_date")
from_utc  <- format(if (is.null(last_cmj)) as.POSIXct("2026-01-01T00:00:00Z", tz="UTC") else last_cmj-days(1), "%Y-%m-%dT%H:%M:%SZ")
cat("[VALD Sync] ForceDecks from:", from_utc, "\n")

all_fd <- list()
current_from <- from_utc
repeat {
  fd_page <- vald_get("/tests", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = current_from), base_url = VALD_FD_BASE)
  if (is.null(fd_page) || length(fd_page) == 0) break
  all_fd <- c(all_fd, list(fd_page))
  if (length(fd_page) < 50) break
  page_df <- as.data.frame(fd_page)
  names(page_df) <- gsub("^tests\\.", "", names(page_df))
  current_from <- page_df$modifiedDateUtc[nrow(page_df)]
  cat("[VALD Sync] Fetched", length(fd_page), "tests, continuing from", current_from, "\n")
  Sys.sleep(0.5)
}
fd_raw <- if (length(all_fd) > 0) do.call(c, all_fd) else NULL
cat("[VALD Sync] Total ForceDecks tests fetched:", length(fd_raw), "\n")

if (!is.null(fd_raw) && length(fd_raw) > 0) {
  fdf <- as.data.frame(fd_raw)
  names(fdf) <- gsub("^tests\\.", "", names(fdf))
  cat("[VALD Sync] ForceDecks columns:", paste(names(fdf), collapse=", "), "\n")
  cat("[VALD Sync] Sample recordedDateUtc:", fdf$recordedDateUtc[1], "\n")
  cat("[VALD Sync] Sample parameter:", jsonlite::toJSON(fdf$parameter[1,], auto_unbox=TRUE), "\n")
  cat("[VALD Sync] Sample extendedParameters row 1:", jsonlite::toJSON(fdf$extendedParameters[[1]], auto_unbox=TRUE), "\n")
  
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
    # Extract all params for each row safely
    # Fetch trials for each test to get actual metrics
    cat("[VALD Sync] Fetching trials for", nrow(fd_df), "tests...\n")
    
    get_trial_metric <- function(trials, keywords) {
      if (is.null(trials) || length(trials) == 0) return(NA_real_)
      if (!is.data.frame(trials)) return(NA_real_)
      if (!"results" %in% names(trials)) return(NA_real_)
      for (i in seq_len(nrow(trials))) {
        res <- trials$results[[i]]
        if (is.null(res) || !is.data.frame(res)) next
        for (j in seq_len(nrow(res))) {
          rid <- as.character(res$resultId[j])
          rname <- tolower(rd_lookup[[rid]] %||% "")
          if (any(sapply(keywords, function(k) grepl(k, rname, fixed=TRUE)))) {
            return(as.numeric(res$value[j]))
          }
        }
      }
      NA_real_
    }

    CMJ_TYPES <- c("CMJ","CMJA","CMJL","SJ","SJA","DJ","DJA","IMTP","HOP")
    trial_data <- lapply(seq_len(nrow(fd_df)), function(i) {
      tid <- fd_df$testId[i]
      ttype <- toupper(fd_df$testType[i])
      if (!any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed=TRUE)))) return(NULL)
      tr <- vald_get(
        paste0("/v2019q3/teams/", VALD_TEAM_ID, "/tests/", tid, "/trials"),
        query = list(),
        base_url = VALD_FD_BASE
      )
      Sys.sleep(0.1)
      tr
    })

    cmj_rows <- fd_df |>
      mutate(
        jump_height_cm             = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("jump height"))),
        peak_force_n               = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("peak force"))),
        peak_power_w               = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("peak power"))),
        rsi_modified               = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("rsi-modified","rsi modified"))),
        concentric_impulse_ns      = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("concentric impulse"))),
        eccentric_decel_impulse_ns = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("eccentric decel"))),
        asymmetry_index_pct = sapply(seq_len(n()), function(i) get_trial_metric(trial_data[[i]], c("asymmetry","asym","lsi")))      ) |>
      select(vald_test_id, vald_profile_id, athlete_name, test_date,
             jump_height_cm, peak_force_n, peak_power_w, rsi_modified,
             concentric_impulse_ns, eccentric_decel_impulse_ns, asymmetry_index_pct) |>
      filter(!is.na(test_date)) |>
      mutate(across(where(is.numeric), ~ifelse(is.nan(.), NA_real_, .)))

    cat("[VALD Sync]", nrow(cmj_rows), "ForceDecks rows to upsert.\n")
    sb_upsert("cmj_tests", cmj_rows)
  }
} else { cat("[VALD Sync] No new ForceDecks tests.\n") }

# ── Step 4: NordBord ──────────────────────────────────────────────────────
cat("[VALD Sync] Fetching NordBord tests...\n")
last_nord    <- get_last_sync("nordbord_tests", "test_date")
from_utc_nb  <- format(if (is.null(last_nord)) as.POSIXct("2026-01-01T00:00:00Z", tz="UTC") else last_nord-days(1), "%Y-%m-%dT%H:%M:%SZ")
cat("[VALD Sync] NordBord from:", from_utc_nb, "\n")

nb_raw <- vald_get("/tests/v2", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = from_utc_nb), base_url = VALD_NORD_BASE)

if (!is.null(nb_raw) && length(nb_raw) > 0) {
  nb_df <- tryCatch({
    ndf <- as.data.frame(nb_raw)
    names(ndf) <- gsub("^tests\\.", "", names(ndf))
    cat("[VALD Sync] NordBord columns:", paste(names(ndf), collapse=", "), "\n")
    ndf |>
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
          !is.na(left_peak_force_n) & !is.na(right_peak_force_n) & pmax(left_peak_force_n,right_peak_force_n)>0 ~
            round(pmin(left_peak_force_n,right_peak_force_n)/pmax(left_peak_force_n,right_peak_force_n)*100, 1),
          TRUE ~ NA_real_
        ),
        bw_ratio = NA_real_
      ) |>
      select(vald_test_id, vald_profile_id, athlete_name, test_date,
             left_peak_force_n, right_peak_force_n, lsi_pct, bw_ratio) |>
      filter(!is.na(test_date))
    cat("[VALD Sync]", nrow(nord_rows), "NordBord rows to upsert.\n")
    sb_upsert("nordbord_tests", nord_rows)
  }
} else { cat("[VALD Sync] No new NordBord tests.\n") }

cat("[VALD Sync] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")