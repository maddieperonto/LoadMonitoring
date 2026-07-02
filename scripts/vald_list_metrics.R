library(httr2)

VALD_CLIENT_ID     <- Sys.getenv("VALD_CLIENT_ID")
VALD_CLIENT_SECRET <- Sys.getenv("VALD_CLIENT_PASSWORD")
VALD_TOKEN_URL      <- "https://auth.prd.vald.com/oauth/token"
VALD_FD_BASE        <- "https://prd-use-api-extforcedecks.valdperformance.com"

token_resp <- request(VALD_TOKEN_URL) |>
  req_method("POST") |>
  req_body_form(
    grant_type    = "client_credentials",
    client_id     = VALD_CLIENT_ID,
    client_secret = VALD_CLIENT_SECRET,
    audience      = "vald-api-external"
  ) |>
  req_perform()

access_token <- resp_body_json(token_resp)$access_token
cat("Token obtained.\n")

rd_resp <- request(paste0(VALD_FD_BASE, "/resultdefinitions")) |>
  req_auth_bearer_token(access_token) |>
  req_headers(Accept = "application/json") |>
  req_perform()

rd_data <- resp_body_json(rd_resp, simplifyVector = TRUE)
rd_df <- as.data.frame(rd_data)
if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))

cat("\n===== ALL RESULT NAMES =====\n")
cat(paste(sort(unique(rd_df$resultName)), collapse = "\n"), "\n")
cat("===== END =====\n")