# stats-dumpy

A single-file R Shiny app for browsing [American Soccer Analysis](https://www.americansocceranalysis.com/) (ASA) player data — xG, xPass, Goals Added (g+), and salaries — across MLS, NWSL, MLS Next Pro, USL Super League, USL Championship, USL League One, and NASL.

Data comes live from ASA via the [`itscalledsoccer`](https://github.com/American-Soccer-Analysis/itscalledsoccer) R client, with an in-memory cache in front of it (see "Caching" below) — nothing is persisted to disk or checked into this repo.

## Running it

```r
# install.packages("pak")  # if you don't have pak yet
pak::pak(c("shiny", "bslib", "bsicons", "itscalledsoccer", "dplyr", "tidyr", "DT", "memoise", "cachem"))
shiny::runApp("app.R")
```

## What it does

The sidebar controls what gets fetched:

- **Leagues** — one or more leagues to pull (default: USL Super League)
- **Seasons** — blank means all seasons available for the selected league(s); options repopulate when you change leagues. Multi-year leagues (USL Championship, USL League One, USL Super League) are labeled `YYYY-yy` (e.g. `2025-26`) — except USL Super League from the 2026 season onward, which ASA labels as a plain `YYYY` year (`2026`, not `2026-27`), a break from its own prior convention. `SINGLE_YEAR_SEASON_FROM` in `app.R` controls the cutoff per league if this happens elsewhere too.
- **Aggregate across seasons** — appears once 0 or 2+ seasons are selected (a single season has nothing to aggregate). Off by default: each selected season stays its own row (`split_by_seasons = TRUE` sent to ASA), same as picking one season at a time. Turn it on to combine the selected seasons into one row per player instead — useful for a multi-season total rather than a year-by-year breakdown. Team splits are unaffected either way: a player who changed teams still gets one row per team. Since ASA's response doesn't include a `season_name` at all once seasons are combined, the app re-adds it as a concatenated label of the seasons involved (e.g. `2025-26, 2024-25`, or `All seasons` when Seasons was left blank), so it's still clear what a row covers.
- **Minimum Minutes** — filters small-sample players out of the currently loaded data instantly, with no re-fetch (see "Caching" below)
- **Fetch Stats** — pulls the full league/season roster from ASA (or from cache, if already fetched recently)
- **Force Refresh** — bypasses the cache and re-fetches from ASA immediately, for when you know something changed (e.g. right after a match)
- **Download CSV** — exports whichever table (Aggregate or Game Stats) is currently active, filtered by Minimum Minutes

Three tabs consume that data:

### Aggregate Stats

Season-level totals, one row per player-team-season. A dropdown switches between three stat families:

- **xGoals + xPass** — shooting (`xgoals`, `shots`, etc.), passing (`xpass_completion_percentage`, `attempted_passes`), goalkeeper shot-stopping columns when available, and the full Goals Added breakdown joined in (see below). This is also the dataset the Player Cards tab depends on.
- **Goals Added** — ASA's g+ model, pivoted so each row is one player with a column per action component (`ga_passing`, `ga_receiving`, `ga_dribbling`, `ga_shooting`, `ga_interrupting`, `ga_fouling` for outfield players; goalkeepers get their own component set), plus a `goals_added` total. See "Goals Added components" below.
- **Salaries** — raw salary data from ASA, where available.

### Game Stats

The same xG/xPass/g+ shape as Aggregate Stats, but split out per player-per-game instead of summed across the season. Useful for spotting form and outliers a season total would smooth over.

### Player Cards

A rated, position-grouped card view built on top of the Aggregate Stats ("xGoals + xPass") data — including the Aggregate across seasons toggle, so a multi-season composite rating is one checkbox away from a year-by-year one. For each position group, players are:

1. Filtered to those above the 25th-percentile of minutes played *within that position group* (so bit-part players don't clutter the rankings). This is a separate, stricter filter than the sidebar's Minimum Minutes — it's computed dynamically per position group, so a player can pass Minimum Minutes and still be excluded from cards. A "Hide low-minute outliers" checkbox above the cards (on by default) lets you turn this off to see everyone who otherwise met Minimum Minutes, including small-sample players whose per-96 rates are noisy.
2. Scored on a 0–100 **composite** rating, computed from a different weighted blend of percentile ranks per position (see `compute_ratings()` in `app.R`):
   - **FW**: xG/96, g+/96, shot-on-target %, xPass%
   - **MF**: g+/96, xPass%, xG/96, passes/96
   - **FB**: xPass%, g+/96, passes/96, xG/96
   - **CB**: g+/96, xPass%, passes/96, xG/96
   - **GK**: g+/96, goals prevented/96, save %
3. Ranked within their position group and rendered as a card showing the composite score, rank, and four key stat tiles with percentile coloring (green/yellow/red)

The displayed tiles aren't always identical to the composite inputs above — FB and CB cards swap in `ga_interrupting_p96` ("Int+/96") as a defense-specific stat instead of always showing the flattened g+/96 total, since g+'s six action components (see below) let defenders be judged on the component that actually reflects defending rather than a blended on/off-ball score. CB leads with Int+/96; FB shows it as its second tile alongside xPass%, since fullback play still leans more attacking.

## Goals Added components

ASA's Goals Added (g+) model scores every outfield player on the same set of on-ball action types (dribbling, fouling, interrupting, passing, receiving, shooting) — it's a positionless "common currency" of value, not a position-specific stat. Goalkeepers run through a separate model with their own action types. This app fetches that per-action breakdown (`fetch_ga_totals()`) and pivots it into wide columns (`ga_<action_type>`) rather than only exposing the summed total, so you can see e.g. how much of a center back's value comes from `ga_interrupting` vs. `ga_passing`.

Every component also gets a `_p96` (per-96-minutes) counterpart — the same normalization convention used throughout the app for `xgoals_p96`, `passes_p96`, etc. — since raw totals aren't comparable across players with different playing time.

A component column is `NA`, not `0`, for any player whose role doesn't include that action type at all — e.g. `ga_sweeping` is blank for outfield players and `ga_dribbling` is blank for goalkeepers, since they're never evaluated on it in the first place. This mirrors how other position-specific stats (like `save_pct` for non-goalkeepers) already show blank rather than a misleading zero.

## Caching

Fetching a full league/season roster from ASA is the slow part, so every ASA endpoint call is wrapped with [`memoise`](https://memoise.r-lib.org/) backed by an in-memory [`cachem::cache_mem()`](https://cachem.r-lib.org/) with a 6-hour TTL (`.memoize_asa()` in `app.R`). Memoization happens at the individual endpoint level (`get_player_xgoals`, `get_player_goals_added`, `get_players`, etc. — see the `cached` list near the top of `app.R`), not around the higher-level `fetch_agg()`/`fetch_games()` functions, so the cache is shared across tabs and stat types that hit the same underlying endpoint. Each endpoint gets its own dedicated cache instance rather than sharing one — memoise's cache-key hashing can't reliably distinguish between different endpoints' identically-shaped wrapper closures when they're called with the same arguments, so sharing a single cache risked one endpoint's result being served for another's request.

The **Minimum Minutes** filter is intentionally *not* part of the cached request: every fetch always pulls the full roster (`minimum_minutes = 0`), and the threshold is applied afterward as a local `dplyr::filter()` (`apply_min_minutes()`). That decoupling is what makes the slider instant — it never re-hits the API or even the cache, it just re-filters data already in memory — and it also means every distinct Minimum Minutes value doesn't fragment the cache into separate entries.

The cache is in-memory and process-scoped: it's shared across concurrent users of the same running app instance, and clears on cold start/redeploy. That's a deliberate tradeoff for a hosted app where a persistent on-disk cache isn't guaranteed to survive container restarts. The 6-hour TTL and the **Force Refresh** button (which calls `memoise::forget()` on every cached endpoint before re-fetching) cover the case where ASA's data updates mid-window.

## Known gaps

- ASA doesn't expose raw defensive counting stats (tackles, interceptions, clearances, aerials) — g+'s `interrupting` component is the closest available proxy, which is why the CB/FB cards use it instead of anything more granular.
