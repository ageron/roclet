# Plotly.js 4.2.0

`plotly.min.js` is the unchanged full distribution from
https://cdn.plot.ly/plotly-4.2.0.min.js, matching Plume 0.5.0.
Its SHA-384 was checked against the integrity value in Plume's `Chart.to_html`.
Download URLs and SHA-256 checksums are recorded in `lock.json`.

Upstream: https://github.com/plotly/plotly.js — MIT, see LICENSE.
The full bundle supports every Plume trace, including Sankey diagrams.
Roclet loads it only inside isolated chart frames and includes it in offline
distributions. Updating this file should include browser chart validation.
