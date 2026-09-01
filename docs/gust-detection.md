# Gust detection

Used by `_WindHistory` in [`lib/utils/trackers.dart`](../lib/utils/trackers.dart) for both the VNT screen's AWS/TWS cards and the ANC (anchor watch) screen's wind readout/arrow.

## The problem with "highest reading in the last N minutes"

The original implementation just tracked the maximum raw wind sample seen in a trailing window. That flags perfectly steady strong wind as a "gust" the instant it happens to be the biggest number recently seen, with no regard for whether it was actually a spike, or whether it lasted long enough to mean anything at all.

## The method

Every new sample, over a rolling 10-minute window, compute:

1. **Mean** (`Ū₁₀ₘ`) — the average of all readings in the last 10 minutes.
2. **Standard deviation** (`σ₁₀ₘ`) — how much those readings vary around that mean.
3. **Recent peak** (`u_max`) — the highest raw reading in the last 3 seconds.

A gust is confirmed only when **both** hold:

```
u_max ≥ Ū₁₀ₘ + 3·σ₁₀ₘ
u_max − Ū₁₀ₘ ≥ 5 m/s   (≈ 9.7 kn)
```

- **The 3σ test** is the statistical-outlier check: a reading in the top ~0.3% of the recent distribution (assuming roughly normal variation) is treated as a genuine outlier rather than ordinary noise.
- **The 5 m/s floor** exists because the 3σ test alone misfires in near-calm-but-twitchy conditions — a tiny, jittery breeze can easily produce a 3σ "outlier" that's a fraction of a knot above the mean and means nothing on a boat. Requiring an absolute minimum jump keeps that from registering as a gust.

Pseudocode:

```
1. Read current_speed every ~1s (or on every anemometer sample).
2. Keep a 10-minute rolling buffer and a 3-second rolling buffer.
3. mean   = average(10min buffer)
4. stddev = stddev(10min buffer)
5. u_max  = max(3s buffer)
6. if u_max >= mean + 3*stddev AND u_max - mean >= 5 m/s:
       gust_confirmed = u_max
   else:
       sustained_wind = mean
```

This is the same structure meteorological services use to define a gust (WMO: peak of a 3-second running mean, evaluated against a baseline over an observing window — see the [WMO gust variable definition](https://space.oscar.wmo.int/variables/view/wind_gust)), with one deliberate change: WMO's baseline comparison uses a fixed absolute margin, this implementation instead requires a *statistical* outlier (3σ) with that fixed margin (5 m/s) only as a floor — so it scales with how gusty conditions already are, rather than needing the same fixed jump in 5kn breeze as in a 30kn blow.

## Implementation notes

- `_updateGustState()` runs on every `add()` call and requires at least 30 samples in the baseline window before it will confirm anything — not enough history yet to trust a standard deviation otherwise.
- `isGusting()` is true only while the most recent confirmation is still within the 3-second peak window — i.e. "gusting right now", not "gusted recently".
- `statisticalGustWithAge()` returns the last confirmed gust's value and how long ago it happened, for a "racha de hace N min" style readout even after the gust itself has passed.
