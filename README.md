# stats-dumpy

A single-file R Shiny app for browsing [American Soccer Analysis](https://www.americansocceranalysis.com/) (ASA) player data — xG, xPass, Goals Added (g+), and salaries — across MLS, NWSL, MLS Next Pro, USL Super League, USL Championship, USL League One, and NASL.

Data comes live from ASA via the [`itscalledsoccer`](https://github.com/American-Soccer-Analysis/itscalledsoccer) R client; nothing is cached or checked into this repo.

## Running it

```r
install.packages(c("shiny", "bslib", "bsicons", "itscalledsoccer", "dplyr", "tidyr", "DT"))
shiny::runApp("app.R")
```

## What it does

The sidebar controls what gets fetched:

- **Leagues** — one or more leagues to pull (default: USL Super League)
- **Seasons** — blank means all seasons available for the selected league(s); options repopulate when you change leagues
- **Minimum Minutes** — filter out small-sample players before fetching
- **Fetch Stats** — pulls fresh data from ASA for the current filters
- **Download CSV** — exports whichever table (Aggregate or Game Stats) is currently active

Three tabs consume that data:

### Aggregate Stats

Season-level totals, one row per player-team-season. A dropdown switches between three stat families:

- **xGoals + xPass** — shooting (`xgoals`, `shots`, etc.), passing (`xpass_completion_percentage`, `attempted_passes`), goalkeeper shot-stopping columns when available, and the full Goals Added breakdown joined in (see below). This is also the dataset the Player Cards tab depends on.
- **Goals Added** — ASA's g+ model, pivoted so each row is one player with a column per action component (`ga_passing`, `ga_receiving`, `ga_dribbling`, `ga_shooting`, `ga_interrupting`, `ga_fouling` for outfield players; goalkeepers get their own component set), plus a `goals_added` total. See "Goals Added components" below.
- **Salaries** — raw salary data from ASA, where available.

### Game Stats

The same xG/xPass/g+ shape as Aggregate Stats, but split out per player-per-game instead of summed across the season. Useful for spotting form and outliers a season total would smooth over.

### Player Cards

A rated, position-grouped card view built on top of the Aggregate Stats ("xGoals + xPass") data. For each position group, players are:

1. Filtered to those above the 25th-percentile of minutes played *within that position group* (so bit-part players don't clutter the rankings)
2. Scored on a 0–100 **composite** rating, computed from a different weighted blend of percentile ranks per position (see `compute_ratings()` in `app.R`):
   - **FW**: xG/96, g+/96, shot-on-target %, xPass%
   - **MF**: g+/96, xPass%, xG/96, passes/96
   - **FB** / **CB**: g+/96, xPass%, passes/96, xG/96 (weighted differently between the two)
   - **GK**: g+/96, goals prevented/96, save %
3. Ranked within their position group and rendered as a card showing the composite score, rank, and four key stat tiles with percentile coloring (green/yellow/red)

## Goals Added components

ASA's Goals Added (g+) model scores every outfield player on the same set of on-ball action types (dribbling, fouling, interrupting, passing, receiving, shooting) — it's a positionless "common currency" of value, not a position-specific stat. Goalkeepers run through a separate model with their own action types. This app fetches that per-action breakdown (`fetch_ga_totals()`) and pivots it into wide columns (`ga_<action_type>`) rather than only exposing the summed total, so you can see e.g. how much of a center back's value comes from `ga_interrupting` vs. `ga_passing`.

Every component also gets a `_p96` (per-96-minutes) counterpart — the same normalization convention used throughout the app for `xgoals_p96`, `passes_p96`, etc. — since raw totals aren't comparable across players with different playing time.

## Known gaps

- The Player Cards' FB and CB tiles currently show the same four stats (differing only in priority order) rather than pulling position-relevant g+ components (e.g. `ga_interrupting_p96` for CBs) — the data is available via the Aggregate Stats "Goals Added" table, just not wired into the card logic yet.
- ASA doesn't expose raw defensive counting stats (tackles, interceptions, clearances, aerials) — g+'s `interrupting` component is the closest available proxy.
