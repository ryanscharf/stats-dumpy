library(shiny)
library(bslib)
library(bsicons)
library(itscalledsoccer)
library(dplyr)
library(tidyr)
library(DT)
library(memoise)
library(cachem)

# --- helpers ------------------------------------------------------------------

# In-memory caching, scoped per ASA endpoint, shared across all sessions of
# this running app instance. Short TTL because ASA's underlying data changes
# as games are played; a "Force Refresh" button (see UI) lets users bypass
# it on demand.
CACHE_TTL_SECONDS <- 6 * 60 * 60

asa <- AmericanSoccerAnalysis$new()

# Memoize at the level of individual ASA endpoints (not the higher-level
# fetch_* functions) so the cache is shared across tabs/stat types that
# hit the same endpoint with the same arguments.
#
# Each R6 method is wrapped in a plain `function(...)` closure before being
# memoised, rather than memoising the bound method directly — memoise
# introspects the wrapped function's formals to build the cache key, and
# an R6 bound method's formals/environment confuse that (fails with
# "argument \"names\" is missing" deep inside memoise's key hashing).
#
# Each endpoint gets its OWN cache instance rather than sharing one — the
# wrapper closures below are textually identical (`function(...) fn(...)`)
# across every endpoint, and memoise's cache-key hashing doesn't distinguish
# between different closures with the same body/formals when called with
# the same arguments. Sharing one cache caused get_teams() and get_players()
# (both called with e.g. `leagues = list("usls")`) to collide onto the same
# entry, silently serving one endpoint's result for the other.
.memoize_asa <- function(fn) {
  memoise::memoise(
    function(...) fn(...),
    cache = cachem::cache_mem(
      max_age = CACHE_TTL_SECONDS,
      max_size = 500 * 1024^2
    )
  )
}

cached <- list(
  get_player_xgoals = .memoize_asa(asa$get_player_xgoals),
  get_player_xpass = .memoize_asa(asa$get_player_xpass),
  get_goalkeeper_xgoals = .memoize_asa(asa$get_goalkeeper_xgoals),
  get_player_goals_added = .memoize_asa(asa$get_player_goals_added),
  get_goalkeeper_goals_added = .memoize_asa(asa$get_goalkeeper_goals_added),
  get_player_salaries = .memoize_asa(asa$get_player_salaries),
  get_players = .memoize_asa(asa$get_players),
  get_teams = .memoize_asa(asa$get_teams)
)

LEAGUES <- c(
  "MLS" = "mls",
  "NWSL" = "nwsl",
  "MLS Next Pro" = "mlsnp",
  "USL Super League" = "usls",
  "USL-C" = "uslc",
  "USL1" = "usl1",
  "NASL" = "nasl"
)

AGG_STAT_TYPES <- c(
  "xGoals + xPass" = "xgoals_xpass",
  "Goals Added" = "goals_added",
  "Salaries" = "salaries"
)

# Canonical column order for the Aggregate/Game Stats tables and CSV
# download, applied by attach_names() via intersect() + everything() — so
# it degrades gracefully (unlisted columns just fall through to the end)
# regardless of which stat_type produced the data.
COLUMN_ORDER <- c(
  # identity / meta
  "player_id",
  "player_name",
  "team_abbreviation",
  "team_id",
  "general_position",
  "primary_broad_position",
  "birth_date",
  "season_name",
  "competition",
  "game_id",
  "date",
  # playing time
  "minutes_played",
  "count_games",
  # attacking output
  "shots",
  "shots_on_target",
  "goals",
  "xgoals",
  "xplace",
  "goals_minus_xgoals",
  "key_passes",
  "primary_assists",
  "xassists",
  "primary_assists_minus_xassists",
  "goals_plus_primary_assists",
  "xgoals_plus_xassists",
  "points_added",
  "xpoints_added",
  # passing
  "attempted_passes",
  "pass_completion_percentage",
  "xpass_completion_percentage",
  "passes_completed_over_expected",
  "passes_completed_over_expected_p100",
  "avg_distance_yds",
  "avg_vertical_distance_yds",
  "share_team_touches",
  # goalkeeping
  "shots_faced",
  "goals_conceded",
  "saves",
  "sv_pct",
  "xsv_pct",
  "sv_pct_plus_minus",
  "share_headed_shots",
  "xgoals_gk_faced",
  "goals_minus_xgoals_gk",
  "goals_divided_by_xgoals_gk",
  # goals added — raw components, then total, then their p96 counterparts
  "ga_dribbling",
  "ga_fouling",
  "ga_interrupting",
  "ga_passing",
  "ga_receiving",
  "ga_shooting",
  "ga_claiming",
  "ga_fielding",
  "ga_handling",
  "ga_shotstopping",
  "ga_sweeping",
  "goals_added",
  "ga_dribbling_p96",
  "ga_fouling_p96",
  "ga_interrupting_p96",
  "ga_passing_p96",
  "ga_receiving_p96",
  "ga_shooting_p96",
  "ga_claiming_p96",
  "ga_fielding_p96",
  "ga_handling_p96",
  "ga_shotstopping_p96",
  "ga_sweeping_p96",
  "goals_added_p96"
)

MULTISEASON_LEAGUES <- c("uslc", "usl1", "usls")

# USL Super League broke from the "YYYY-yy" split-year naming it used for
# 2024-25/2025-26 starting with the 2026 season, which ASA labels as the
# plain year "2026" (no dash) — apparently a move to calendar-year seasons.
# Maps league -> first year that uses plain-year naming instead of dash
# naming, for leagues in MULTISEASON_LEAGUES.
SINGLE_YEAR_SEASON_FROM <- list(usls = 2026L)

POSITION_MAP <- c(
  "GK" = "GK",
  "Goalkeeper" = "GK",
  "CB" = "CB",
  "Center Back" = "CB",
  "FB" = "FB",
  "LB" = "FB",
  "RB" = "FB",
  "WB" = "FB",
  "Fullback" = "FB",
  "Back" = "FB",
  "CM" = "MF",
  "DM" = "MF",
  "AM" = "MF",
  "MF" = "MF",
  "Midfielder" = "MF",
  "Defensive Midfielder" = "MF",
  "Central Midfielder" = "MF",
  "Attacking Midfielder" = "MF",
  "W" = "FW",
  "LW" = "FW",
  "RW" = "FW",
  "Winger" = "FW",
  "ST" = "FW",
  "CF" = "FW",
  "FW" = "FW",
  "Forward" = "FW",
  "Striker" = "FW"
)

LEAGUE_YEARS <- list(
  mls = c(2013L, 2026L),
  nwsl = c(2016L, 2026L),
  mlsnp = c(2022L, 2026L),
  usls = c(2024L, 2026L),
  uslc = c(2011L, 2026L),
  usl1 = c(2019L, 2026L),
  nasl = c(2013L, 2017L)
)

valid_seasons_for <- function(leagues) {
  seasons <- character(0)
  for (lg in leagues) {
    span <- LEAGUE_YEARS[[lg]]
    if (is.null(span)) {
      next
    }
    yrs <- span[1]:span[2]
    is_dash <- rep(lg %in% MULTISEASON_LEAGUES, length(yrs))
    single_year_from <- SINGLE_YEAR_SEASON_FROM[[lg]]
    if (!is.null(single_year_from)) {
      is_dash <- is_dash & (yrs < single_year_from)
    }
    formatted <- ifelse(
      is_dash,
      paste0(yrs, "-", substr(yrs + 1L, 3, 4)),
      as.character(yrs)
    )
    seasons <- union(seasons, formatted)
  }
  seasons[order(substr(seasons, 1, 4), decreasing = TRUE)]
}

player_args <- function(leagues, seasons, aggregate_seasons = FALSE) {
  list(
    leagues = as.list(leagues),
    season_name = if (length(seasons) == 0) NULL else as.list(seasons),
    minimum_minutes = 0L,
    split_by_seasons = !aggregate_seasons,
    split_by_teams = TRUE
  )
}

apply_min_minutes <- function(df, min_minutes) {
  if (is.null(df) || !"minutes_played" %in% names(df)) {
    return(df)
  }
  filter(df, minutes_played >= min_minutes)
}

attach_names <- function(df, leagues) {
  leagues_arg <- as.list(leagues)

  if ("player_id" %in% names(df)) {
    players <- cached$get_players(leagues = leagues_arg)
    if (!is.null(players) && nrow(players) > 0) {
      cols <- intersect(
        c(
          "player_id",
          "player_name",
          "birth_date",
          "primary_broad_position",
          "general_position"
        ),
        names(players)
      )
      df <- left_join(df, select(players, all_of(cols)), by = "player_id")
    }
  }

  if ("team_id" %in% names(df)) {
    teams <- cached$get_teams(leagues = leagues_arg)
    if (
      !is.null(teams) &&
        nrow(teams) > 0 &&
        "team_abbreviation" %in% names(teams)
    ) {
      df <- left_join(
        df,
        select(teams, team_id, team_abbreviation),
        by = "team_id"
      )
    }
  }

  front <- intersect(COLUMN_ORDER, names(df))
  select(df, all_of(front), everything())
}

log_call <- function(fn, leagues, seasons) {
  message(sprintf(
    "%s(leagues = %s, season_name = %s)",
    fn,
    paste(leagues, collapse = ", "),
    if (length(seasons) == 0) "NULL" else paste(seasons, collapse = ", ")
  ))
}

pct_rank <- function(x) {
  n <- sum(!is.na(x))
  if (n < 2) {
    return(rep(NA_real_, length(x)))
  }
  rank(x, ties.method = "average", na.last = "keep") / n * 100
}

compute_ratings <- function(
  df,
  leagues = NULL,
  gk_agg = NULL,
  apply_minutes_floor = TRUE
) {
  if (is.null(df)) {
    return(NULL)
  }

  pos_col <- intersect(
    c("primary_broad_position", "general_position"),
    names(df)
  )[1]

  if (is.na(pos_col) && !is.null(leagues)) {
    players <- tryCatch(
      cached$get_players(leagues = as.list(leagues)),
      error = function(e) NULL
    )
    if (!is.null(players) && nrow(players) > 0) {
      pos_col <- intersect(
        c("primary_broad_position", "general_position"),
        names(players)
      )[1]
      if (!is.na(pos_col)) {
        df <- left_join(
          df,
          select(players, player_id, all_of(pos_col)),
          by = "player_id"
        )
      }
    }
  }

  if (
    is.na(pos_col) || !all(c("minutes_played", "goals_added") %in% names(df))
  ) {
    return(NULL)
  }

  for (col in c(
    "xgoals",
    "shots",
    "shots_on_target",
    "xpass_completion_percentage",
    "attempted_passes",
    "ga_interrupting_p96"
  )) {
    if (!col %in% names(df)) df[[col]] <- NA_real_
  }

  df <- df |>
    mutate(pos_group = unname(POSITION_MAP[.data[[pos_col]]])) |>
    filter(!is.na(pos_group), !is.na(minutes_played), minutes_played > 0)

  # Small-sample players (a handful of good/bad touches in limited minutes)
  # can produce wild per-96 rates and skew rankings, so by default each
  # position group excludes anyone below its own 25th-percentile of minutes
  # played. This is separate from — and stricter than — the sidebar's
  # Minimum Minutes filter, and can be turned off via apply_minutes_floor.
  if (apply_minutes_floor) {
    df <- df |>
      group_by(pos_group) |>
      mutate(min_thresh = quantile(minutes_played, 0.25, na.rm = TRUE)) |>
      filter(minutes_played > min_thresh) |>
      select(-min_thresh) |>
      ungroup()
  }

  if (nrow(df) == 0) {
    return(NULL)
  }

  # GK-specific column detection
  gk_shots_col <- intersect(
    c("shots_on_target_faced", "shots_faced"),
    names(df)
  )[1]
  gk_gc_col <- intersect(c("goals_conceded", "goals_against"), names(df))[1]
  gk_xg_col <- intersect(
    c("xgoals_gk", "xgoals_against", "xgoals_faced"),
    names(df)
  )[1]

  for (col in c("save_pct", "goals_prevented_p96", "shots_faced_p96")) {
    if (!col %in% names(df)) df[[col]] <- NA_real_
  }

  if (!is.na(gk_shots_col) && !is.na(gk_gc_col)) {
    df <- df |>
      mutate(
        save_pct = (.data[[gk_shots_col]] - .data[[gk_gc_col]]) /
          pmax(.data[[gk_shots_col]], 1),
        shots_faced_p96 = .data[[gk_shots_col]] / pmax(minutes_played, 1) * 96
      )
  }

  if (!is.null(gk_agg) && "goals_minus_xgoals_gk" %in% names(gk_agg)) {
    keys <- intersect(
      c("player_id", "team_id", "season_name"),
      intersect(names(df), names(gk_agg))
    )
    df <- select(df, -any_of("goals_minus_xgoals_gk"))
    df <- left_join(
      df,
      select(gk_agg, all_of(keys), goals_minus_xgoals_gk),
      by = keys
    )
    df <- df |>
      mutate(
        goals_prevented_p96 = -goals_minus_xgoals_gk /
          pmax(minutes_played, 1) *
          96
      )
  } else if (!is.na(gk_xg_col) && !is.na(gk_gc_col)) {
    df <- df |>
      mutate(
        goals_prevented_p96 = (.data[[gk_xg_col]] - .data[[gk_gc_col]]) /
          pmax(minutes_played, 1) *
          96
      )
  }

  if (!"birth_date" %in% names(df)) {
    df[["birth_date"]] <- NA_character_
  }

  df |>
    mutate(
      xgoals_p96 = xgoals / minutes_played * 96,
      goals_added_p96 = goals_added / minutes_played * 96,
      shot_on_target_pct = shots_on_target / pmax(shots, 1),
      xpass_pct = xpass_completion_percentage * 100,
      passes_p96 = attempted_passes / minutes_played * 96,
      age = floor(
        as.numeric(Sys.Date() - suppressWarnings(as.Date(birth_date))) / 365.25
      )
    ) |>
    group_by(pos_group) |>
    mutate(
      pct_xg = pct_rank(xgoals_p96),
      pct_ga = pct_rank(goals_added_p96),
      pct_sot = pct_rank(shot_on_target_pct),
      pct_xp = pct_rank(xpass_pct),
      pct_p96 = pct_rank(passes_p96),
      pct_save = pct_rank(save_pct),
      pct_gp96 = pct_rank(goals_prevented_p96),
      pct_sf96 = pct_rank(shots_faced_p96),
      pct_int = pct_rank(ga_interrupting_p96)
    ) |>
    ungroup() |>
    mutate(
      composite = round(
        case_when(
          pos_group == "FW" ~ 0.35 *
            pct_xg +
            0.35 * pct_ga +
            0.15 * pct_sot +
            0.15 * pct_xp,
          pos_group == "MF" ~ 0.30 *
            pct_ga +
            0.30 * pct_xp +
            0.20 * pct_xg +
            0.20 * pct_p96,
          pos_group == "FB" ~ 0.35 *
            pct_xp +
            0.30 * pct_ga +
            0.20 * pct_p96 +
            0.15 * pct_xg,
          pos_group == "CB" ~ 0.45 *
            pct_ga +
            0.35 * pct_xp +
            0.10 * pct_p96 +
            0.10 * pct_xg,
          pos_group == "GK" & !is.na(pct_gp96) ~ 0.40 *
            pct_ga +
            0.40 * pct_gp96 +
            0.20 * pct_save,
          pos_group == "GK" & !is.na(pct_save) ~ 0.60 *
            pct_ga +
            0.40 * pct_save,
          pos_group == "GK" ~ pct_ga,
          TRUE ~ NA_real_
        ),
        0
      )
    ) |>
    group_by(pos_group) |>
    mutate(
      pos_rank = rank(-composite, ties.method = "min", na.last = "keep"),
      pos_total = n()
    ) |>
    ungroup()
}

.slugify <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  gsub("^_|_$", "", x)
}

.append_p96 <- function(df, cols) {
  if (!"minutes_played" %in% names(df)) {
    return(df)
  }
  for (col in cols) {
    df[[paste0(col, "_p96")]] <- df[[col]] / pmax(df$minutes_played, 1) * 96
  }
  df
}

# Returns one row per player (or per player-game, if by_game = TRUE) with:
#   - one ga_<action_type> column per g+ action component (e.g. ga_passing,
#     ga_interrupting), reflecting the fact that ASA scores every outfield
#     player on the same six action types (goalkeepers get their own set)
#   - goals_added, the sum of those components (matches the old behavior)
#   - minutes_played
fetch_ga_totals <- function(
  leagues,
  seasons,
  by_game = FALSE,
  aggregate_seasons = FALSE
) {
  args <- list(
    leagues = as.list(leagues),
    season_name = if (length(seasons) == 0) NULL else as.list(seasons),
    minimum_minutes = 0L,
    # A single game already belongs to exactly one season, so the
    # aggregate/split-by-season toggle only makes sense for the season-level
    # (by_game = FALSE) fetch.
    split_by_seasons = if (by_game) TRUE else !aggregate_seasons,
    split_by_teams = TRUE,
    split_by_games = by_game
  )
  tryCatch(
    {
      raw <- bind_rows(
        unnest(do.call(cached$get_player_goals_added, args), data),
        tryCatch(
          unnest(do.call(cached$get_goalkeeper_goals_added, args), data),
          error = function(e) NULL
        )
      )
      if (!"goals_added_above_avg" %in% names(raw)) {
        return(NULL)
      }
      keys <- intersect(
        c("player_id", "team_id", "season_name", "game_id"),
        names(raw)
      )

      minutes <- raw |>
        group_by(across(all_of(keys))) |>
        summarise(
          minutes_played = if ("minutes_played" %in% names(raw)) {
            first(minutes_played)
          } else {
            NA_real_
          },
          .groups = "drop"
        )

      # values_fill = NA (not 0): a missing (player, action_type) combo means
      # that action type doesn't apply to this player's role at all (e.g. an
      # outfield player has no "Shotstopping" rows, a goalkeeper has no
      # "Dribbling" rows) — not that they were evaluated and scored exactly
      # average. Filling with 0 would misrepresent "not applicable" as "zero
      # value contributed."
      components <- raw |>
        mutate(ga_col = paste0("ga_", .slugify(action_type))) |>
        group_by(across(all_of(keys)), ga_col) |>
        summarise(
          value = sum(goals_added_above_avg, na.rm = TRUE),
          .groups = "drop"
        ) |>
        pivot_wider(
          names_from = ga_col,
          values_from = value,
          values_fill = NA_real_
        )

      component_cols <- setdiff(names(components), keys)

      components |>
        left_join(minutes, by = keys) |>
        mutate(
          goals_added = rowSums(across(all_of(component_cols)), na.rm = TRUE)
        )
    },
    error = function(e) {
      showNotification(
        paste("Error:", conditionMessage(e)),
        type = "error",
        duration = 8
      )
      NULL
    }
  )
}

# Adds three save-percentage stats for goalkeepers (NA for everyone else,
# since the underlying shots_faced/saves/xgoals_gk_faced columns are only
# populated for GK rows):
#   - sv_pct: actual saves as a % of shots faced
#   - xsv_pct: the save % an average keeper would be expected to post,
#     given the quality of shots faced (from xgoals_gk_faced)
#   - sv_pct_plus_minus: sv_pct minus xsv_pct — shot-stopping performance
#     above/below expectation, in percentage points
add_gk_save_pct <- function(df) {
  needed <- c("shots_faced", "saves", "xgoals_gk_faced")
  if (!all(needed %in% names(df))) {
    return(df)
  }
  df |>
    mutate(
      sv_pct = saves / pmax(shots_faced, 1) * 100,
      xsv_pct = (shots_faced - xgoals_gk_faced) / pmax(shots_faced, 1) * 100,
      sv_pct_plus_minus = sv_pct - xsv_pct
    )
}

add_ga_columns <- function(df, ga) {
  if (is.null(ga) || nrow(ga) == 0) {
    return(df)
  }
  keys <- intersect(
    c("player_id", "team_id", "season_name", "game_id"),
    intersect(names(df), names(ga))
  )
  if (length(keys) == 0) {
    return(df)
  }

  value_cols <- setdiff(names(ga), c(keys, "minutes_played"))
  final_names <- ifelse(
    value_cols %in% names(df),
    paste0("total_", value_cols),
    value_cols
  )
  ga_join <- rename(ga, !!!setNames(value_cols, final_names))
  if ("minutes_played" %in% names(df)) {
    ga_join <- select(ga_join, -any_of("minutes_played"))
  }

  df <- left_join(df, ga_join, by = keys)
  .append_p96(df, final_names)
}

fetch_agg <- function(stat_type, leagues, seasons, aggregate_seasons = FALSE) {
  args <- player_args(leagues, seasons, aggregate_seasons)
  log_call(paste0("get_player_", stat_type), leagues, seasons)

  tryCatch(
    {
      df <- if (stat_type == "xgoals_xpass") {
        xg <- do.call(cached$get_player_xgoals, args)
        xp <- do.call(cached$get_player_xpass, args)
        keys <- intersect(
          c("player_id", "team_id", "season_name"),
          intersect(names(xg), names(xp))
        )
        xp_keep <- c(keys, setdiff(names(xp), names(xg)))
        players <- left_join(xg, select(xp, all_of(xp_keep)), by = keys)
        gk <- tryCatch(
          do.call(cached$get_goalkeeper_xgoals, args),
          error = function(e) NULL
        )
        combined <- if (!is.null(gk) && nrow(gk) > 0) {
          gk_keys <- intersect(
            c("player_id", "team_id", "season_name"),
            intersect(names(players), names(gk))
          )
          gk_extra <- c(gk_keys, setdiff(names(gk), names(players)))
          left_join(players, select(gk, all_of(gk_extra)), by = gk_keys)
        } else {
          players
        }
        combined <- add_gk_save_pct(combined)
        ga <- fetch_ga_totals(leagues, seasons, aggregate_seasons = aggregate_seasons)
        add_ga_columns(combined, ga)
      } else {
        switch(
          stat_type,
          goals_added = {
            ga <- fetch_ga_totals(leagues, seasons, aggregate_seasons = aggregate_seasons)
            if (is.null(ga)) {
              NULL
            } else {
              .append_p96(
                ga,
                setdiff(
                  names(ga),
                  c("player_id", "team_id", "season_name", "minutes_played")
                )
              )
            }
          },
          salaries = do.call(cached$get_player_salaries, args)
        )
      }
      # Aggregating drops season_name from ASA's response entirely (there's
      # no longer one row per season to label). Re-add it as a concatenated
      # label of the seasons that went into the total, so it's still clear
      # what's being shown rather than a silently missing column.
      if (aggregate_seasons && !is.null(df) && !"season_name" %in% names(df)) {
        df$season_name <- if (length(seasons) == 0) {
          "All seasons"
        } else {
          paste(seasons, collapse = ", ")
        }
      }
      attach_names(df, leagues)
    },
    error = function(e) {
      showNotification(
        paste("Error:", conditionMessage(e)),
        type = "error",
        duration = 8
      )
      NULL
    }
  )
}

fetch_games <- function(leagues, seasons) {
  args <- list(
    leagues = as.list(leagues),
    season_name = if (length(seasons) == 0) NULL else as.list(seasons),
    minimum_minutes = 0L,
    split_by_games = TRUE,
    split_by_teams = FALSE
  )
  log_call("get_player_xgoals/xpass (split_by_games)", leagues, seasons)
  tryCatch(
    {
      xg <- do.call(cached$get_player_xgoals, args)
      xp <- do.call(cached$get_player_xpass, args)
      keys <- intersect(
        c("player_id", "team_id", "season_name", "game_id", "date"),
        intersect(names(xg), names(xp))
      )
      xp_keep <- c(keys, setdiff(names(xp), names(xg)))
      players <- left_join(xg, select(xp, all_of(xp_keep)), by = keys)
      gk <- tryCatch(
        do.call(cached$get_goalkeeper_xgoals, args),
        error = function(e) NULL
      )
      df <- if (!is.null(gk) && nrow(gk) > 0) {
        gk_keys <- intersect(
          c("player_id", "team_id", "season_name", "game_id", "date"),
          intersect(names(players), names(gk))
        )
        gk_extra <- c(gk_keys, setdiff(names(gk), names(players)))
        left_join(players, select(gk, all_of(gk_extra)), by = gk_keys)
      } else {
        players
      }
      df <- add_gk_save_pct(df)
      ga <- fetch_ga_totals(leagues, seasons, by_game = TRUE)
      df <- add_ga_columns(df, ga)
      attach_names(df, leagues)
    },
    error = function(e) {
      showNotification(
        paste("Error:", conditionMessage(e)),
        type = "error",
        duration = 8
      )
      NULL
    }
  )
}

# --- card helpers -------------------------------------------------------------

.fmt <- function(x, fmt) {
  if (length(x) == 1 && is.na(x)) "—" else sprintf(fmt, x)
}
.ord <- function(x) {
  if (length(x) == 1 && is.na(x)) {
    return("—")
  }
  n <- round(x)
  if (n == 100) {
    return("100th ⭐")
  }
  if (n == 0) {
    return("0th 💩")
  }
  suffix <- if (n %% 100 %in% 11:13) {
    "th"
  } else if (n %% 10 == 1) {
    "st"
  } else if (n %% 10 == 2) {
    "nd"
  } else if (n %% 10 == 3) {
    "rd"
  } else {
    "th"
  }
  paste0(n, suffix)
}
.cls <- function(x) {
  if (length(x) != 1 || is.na(x)) {
    return("text-muted")
  }
  if (x >= 66) {
    "text-success"
  } else if (x >= 33) {
    "text-warning"
  } else {
    "text-danger"
  }
}

make_player_card <- function(row) {
  pos <- row$pos_group

  metric_defs <- switch(
    pos,
    FW = list(
      list("xG/96", .fmt(row$xgoals_p96, "%.2f"), row$pct_xg),
      list("g+/96", .fmt(row$goals_added_p96, "%.3f"), row$pct_ga),
      list("SoT%", .fmt(row$shot_on_target_pct * 100, "%.0f%%"), row$pct_sot),
      list("xPass%", .fmt(row$xpass_pct, "%.0f%%"), row$pct_xp)
    ),
    MF = list(
      list("g+/96", .fmt(row$goals_added_p96, "%.3f"), row$pct_ga),
      list("xPass%", .fmt(row$xpass_pct, "%.0f%%"), row$pct_xp),
      list("xG/96", .fmt(row$xgoals_p96, "%.2f"), row$pct_xg),
      list("P/96", .fmt(row$passes_p96, "%.0f"), row$pct_p96)
    ),
    FB = list(
      list("xPass%", .fmt(row$xpass_pct, "%.0f%%"), row$pct_xp),
      list("Int+/96", .fmt(row$ga_interrupting_p96, "%.3f"), row$pct_int),
      list("P/96", .fmt(row$passes_p96, "%.0f"), row$pct_p96),
      list("xG/96", .fmt(row$xgoals_p96, "%.2f"), row$pct_xg)
    ),
    CB = list(
      list("Int+/96", .fmt(row$ga_interrupting_p96, "%.3f"), row$pct_int),
      list("xPass%", .fmt(row$xpass_pct, "%.0f%%"), row$pct_xp),
      list("P/96", .fmt(row$passes_p96, "%.0f"), row$pct_p96),
      list("g+/96", .fmt(row$goals_added_p96, "%.3f"), row$pct_ga)
    ),
    GK = list(
      list("g+/96", .fmt(row$goals_added_p96, "%.3f"), row$pct_ga),
      list("Sv%", .fmt(row$save_pct * 100, "%.1f%%"), row$pct_save),
      list("GlsPvt/96", .fmt(row$goals_prevented_p96, "%.3f"), row$pct_gp96),
      list("Shots/96", .fmt(row$shots_faced_p96, "%.1f"), row$pct_sf96)
    ),
    list()
  )

  player_name <- if (is.na(row$player_name)) "Unknown" else row$player_name
  team_abbr <- if (is.na(row$team_abbreviation)) "" else row$team_abbreviation
  age_str <- if (!is.null(row$age) && !is.na(row$age)) {
    paste0("Age ", row$age)
  } else {
    NULL
  }
  rank_str <- if (!is.null(row$pos_rank) && !is.na(row$pos_rank)) {
    paste0(.ord(row$pos_rank), " / ", row$pos_total)
  } else {
    NULL
  }

  card(
    class = "h-100",
    card_header(
      class = "d-flex justify-content-between align-items-center py-2",
      tags$strong(player_name),
      tags$div(
        tags$span(class = "badge bg-secondary me-1", pos),
        tags$span(class = "text-muted small", team_abbr)
      )
    ),
    card_body(
      class = "p-2",
      tags$p(
        class = "text-muted small mb-2",
        paste(
          Filter(
            Negate(is.null),
            list(
              paste0(round(row$minutes_played), " min"),
              age_str
            )
          ),
          collapse = " · "
        )
      ),
      tags$div(
        class = paste("text-center mb-1", .cls(row$composite)),
        tags$span(
          class = "fs-2 fw-bold",
          if (is.na(row$composite)) "—" else row$composite
        ),
        tags$div(class = "text-muted small", "composite")
      ),
      if (!is.null(rank_str)) {
        tags$p(
          class = "text-center text-muted mb-2",
          style = "font-size:0.7rem",
          rank_str
        )
      },
      if (length(metric_defs) > 0) {
        tags$div(
          class = "row row-cols-2 g-1 text-center",
          lapply(metric_defs, function(m) {
            tags$div(
              class = "col",
              tags$div(
                class = "border rounded p-1",
                tags$div(
                  class = "text-muted",
                  style = "font-size:0.65rem",
                  m[[1]]
                ),
                tags$div(class = "fw-semibold small", m[[2]]),
                tags$div(class = paste("small", .cls(m[[3]])), .ord(m[[3]]))
              )
            )
          })
        )
      }
    )
  )
}

render_player_cards <- function(ratings) {
  if (is.null(ratings) || nrow(ratings) == 0) {
    return(p(class = "text-muted p-3", "No data available."))
  }

  pos_order <- c("FW", "MF", "FB", "CB", "GK")
  pos_labels <- c(
    FW = "Forwards",
    MF = "Midfielders",
    FB = "Fullbacks",
    CB = "Center Backs",
    GK = "Goalkeepers"
  )

  tagList(lapply(pos_order, function(pos) {
    grp <- ratings |> filter(pos_group == pos) |> arrange(desc(composite))
    if (nrow(grp) == 0) {
      return(NULL)
    }
    cards <- lapply(seq_len(nrow(grp)), function(i) make_player_card(grp[i, ]))
    tagList(
      h5(class = "mt-3 mb-2 fw-semibold border-bottom pb-1", pos_labels[[pos]]),
      do.call(layout_column_wrap, c(list(width = "280px"), cards))
    )
  }))
}

# --- ui -----------------------------------------------------------------------

ui <- page_sidebar(
  title = NULL,
  fillable = TRUE,
  theme = bs_theme(
    bg = "#F0EBE3",
    fg = "#3B2314",
    primary = "#7B4F2E",
    secondary = "#A67C5B",
    base_font = font_google("Inter")
  ),

  sidebar = sidebar(
    width = 280,

    tags$h4(class = "fw-bold mb-3", "Stats Dumpy"),

    checkboxGroupInput(
      "leagues",
      "Leagues",
      choices = LEAGUES,
      selected = "usls"
    ),

    selectizeInput(
      "seasons",
      "Seasons (blank = all)",
      choices = valid_seasons_for("usls"),
      selected = "2026",
      multiple = TRUE,
      options = list(placeholder = "All seasons")
    ),

    conditionalPanel(
      condition = "input.seasons.length != 1",
      checkboxInput(
        "aggregate_seasons",
        "Aggregate across seasons",
        value = FALSE
      )
    ),

    numericInput(
      "min_minutes",
      "Minimum Minutes",
      value = 0,
      min = 0,
      step = 100
    ),

    hr(),

    actionButton("fetch", "Fetch Stats", class = "btn-primary w-100"),

    actionButton("force_refresh", "Force Refresh", class = "w-100 mt-2"),

    hr(),

    downloadButton("download_csv", "Download CSV", class = "w-100")
  ),

  navset_tab(
    id = "tabs",

    nav_panel(
      "Aggregate Stats",
      card(
        height = "calc(100vh - 150px)",
        card_header(
          selectInput(
            "agg_stat_type",
            label = NULL,
            choices = AGG_STAT_TYPES,
            selected = "xgoals_xpass",
            width = "220px"
          )
        ),
        full_screen = TRUE,
        DTOutput("agg_table")
      )
    ),

    nav_panel(
      "Game Stats",
      card(
        height = "calc(100vh - 150px)",
        full_screen = TRUE,
        DTOutput("game_table")
      )
    ),

    nav_panel(
      "Player Cards",
      div(
        style = "height: calc(100vh - 150px); overflow-y: auto; padding: 1rem;",
        div(
          class = "d-flex justify-content-end align-items-center text-muted small mb-1",
          style = "gap: 0.35rem;",
          tags$span(
            "Hide low-minute outliers",
            tags$abbr(
              title = paste(
                "Each position group normally excludes players below its",
                "own 25th-percentile of minutes played, so a handful of",
                "touches in limited minutes can't produce a wild per-96",
                "rate and distort the rankings. This is separate from —",
                "and stricter than — the sidebar's Minimum Minutes filter.",
                "Uncheck to include everyone who otherwise met Minimum",
                "Minutes."
              ),
              style = "cursor: help; text-decoration: none;",
              " (?)"
            )
          ),
          div(
            style = "transform: scale(0.85); margin-bottom: -0.5rem;",
            checkboxInput("pc_minutes_floor", label = NULL, value = TRUE)
          )
        ),
        uiOutput("player_cards")
      )
    )
  )
)

# --- server -------------------------------------------------------------------

server <- function(input, output, session) {
  agg_data_raw <- reactiveVal(NULL)
  game_data_raw <- reactiveVal(NULL)

  # Full (minimum_minutes = 0) rosters, cached at the ASA-endpoint level.
  # The Minimum Minutes filter is applied locally below so moving the
  # slider never triggers a re-fetch.
  agg_data <- reactive(apply_min_minutes(agg_data_raw(), input$min_minutes))
  game_data <- reactive(apply_min_minutes(game_data_raw(), input$min_minutes))

  do_fetch <- function() {
    req(input$leagues)
    agg_data_raw(fetch_agg(
      stat_type = input$agg_stat_type,
      leagues = input$leagues,
      seasons = input$seasons,
      aggregate_seasons = isTRUE(input$aggregate_seasons)
    ))
    game_data_raw(fetch_games(
      leagues = input$leagues,
      seasons = input$seasons
    ))
  }

  session$onFlushed(
    function() {
      isolate(do_fetch())
    },
    once = TRUE
  )

  observeEvent(
    input$leagues,
    {
      years <- if (length(input$leagues) == 0) {
        character(0)
      } else {
        valid_seasons_for(input$leagues)
      }
      keep <- intersect(input$seasons, years)
      updateSelectizeInput(session, "seasons", choices = years, selected = keep)
    },
    ignoreNULL = FALSE
  )

  observeEvent(
    input$agg_stat_type,
    {
      req(input$leagues)
      agg_data_raw(fetch_agg(
        stat_type = input$agg_stat_type,
        leagues = input$leagues,
        seasons = input$seasons,
        aggregate_seasons = isTRUE(input$aggregate_seasons)
      ))
    },
    ignoreInit = TRUE
  )

  observeEvent(
    input$aggregate_seasons,
    {
      req(input$leagues)
      agg_data_raw(fetch_agg(
        stat_type = input$agg_stat_type,
        leagues = input$leagues,
        seasons = input$seasons,
        aggregate_seasons = isTRUE(input$aggregate_seasons)
      ))
    },
    ignoreInit = TRUE
  )

  observeEvent(input$fetch, {
    withProgress(message = "Fetching data from ASA…", value = 0, {
      setProgress(0.2)
      do_fetch()
      setProgress(1)
    })
  })

  observeEvent(input$force_refresh, {
    invisible(lapply(cached, memoise::forget))
    withProgress(message = "Refreshing from ASA…", value = 0, {
      setProgress(0.2)
      do_fetch()
      setProgress(1)
    })
  })

  make_dt <- function(df) {
    df <- select(df, -any_of(c("player_id", "team_id")))
    df <- df |> mutate(across(where(is.numeric), ~ round(.x, 3)))
    datatable(
      df,
      filter = "top",
      rownames = FALSE,
      options = list(
        scrollX = TRUE,
        scrollY = "calc(100vh - 310px)",
        scrollCollapse = TRUE,
        paging = FALSE,
        dom = "ft"
      )
    )
  }

  output$agg_table <- renderDT({
    req(agg_data())
    make_dt(agg_data())
  })
  output$game_table <- renderDT({
    req(game_data())
    make_dt(game_data())
  })

  output$player_cards <- renderUI({
    df <- agg_data()
    if (is.null(df) || !"xgoals" %in% names(df)) {
      return(p(
        class = "text-muted p-3",
        'Switch to "xGoals + xPass" and fetch to see player cards.'
      ))
    }

    gk_agg <- local({
      gd <- game_data()
      if (!is.null(gd) && "goals_minus_xgoals_gk" %in% names(gd)) {
        keys <- intersect(c("player_id", "team_id", "season_name"), names(gd))
        # game_data() is always per-game (never season-aggregated), so it
        # always has season_name. But if seasons are being aggregated
        # together for the ratings df, that key must be dropped here too —
        # otherwise this table keeps one row per season while df has one
        # row per player, and the join below fans each ratings row out into
        # one copy per season. Keyed on the toggle itself, not on whether
        # df has a season_name column — df always has one now (a real value
        # when split, a concatenated label when aggregated), so column
        # presence alone can't distinguish the two anymore.
        if (isTRUE(input$aggregate_seasons)) {
          keys <- setdiff(keys, "season_name")
        }
        gd |>
          group_by(across(all_of(keys))) |>
          summarise(
            goals_minus_xgoals_gk = sum(goals_minus_xgoals_gk, na.rm = TRUE),
            .groups = "drop"
          )
      } else {
        NULL
      }
    })

    ratings <- compute_ratings(
      df,
      input$leagues,
      gk_agg,
      apply_minutes_floor = isTRUE(input$pc_minutes_floor)
    )
    if (is.null(ratings) || nrow(ratings) == 0) {
      return(p(
        class = "text-muted p-3",
        "No players met the minimum minutes threshold."
      ))
    }

    render_player_cards(ratings)
  })

  active_data <- reactive({
    if (identical(input$tabs, "Game Stats")) game_data() else agg_data()
  })

  output$download_csv <- downloadHandler(
    filename = function() {
      tab <- if (identical(input$tabs, "Game Stats")) {
        "game"
      } else {
        input$agg_stat_type
      }
      leagues_str <- paste(input$leagues, collapse = "-")
      seasons_str <- if (length(input$seasons) == 0) {
        "all"
      } else {
        paste(input$seasons, collapse = "-")
      }
      sprintf("asa_%s_%s_%s.csv", tab, leagues_str, seasons_str)
    },
    content = function(file) {
      df <- active_data()
      if (is.null(df)) {
        showNotification(
          "No data to download — fetch stats first.",
          type = "warning"
        )
        return(NULL)
      }
      write.csv(df, file, row.names = FALSE)
    }
  )
}

shinyApp(ui, server)
