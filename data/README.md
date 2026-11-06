# Data

## What is here

`intraday_fraction.csv`: 7,685 rows, one per day × 15-minute slot, 145 days (2025-02-01 to 2025-06-25), slots from 09:45 to 22:45.

| Column | Description |
|---|---|
| `Data` | calendar date |
| `Hora` | slot time (HH:MM), already shifted by the ~1h05 delay with which sales reached the reporting table |
| `dia_semana` | weekday, in Portuguese (`segunda-feira` … `domingo`) |
| `perc_dia` | slot time as a fraction of 24h (e.g. 12:00 = 0.5); the model's main input |
| `Multiplicador` | share of the day's net sales already booked at that slot (0 to ~1); the model's target |

## Where it comes from

The source is a transaction-level net-sales export from a Brazilian retailer (sales and cancellations, ~236k rows, 156 columns). `R/00_extract.R` reads only the 4 columns the model uses (timestamps, movement type, net value), applies the treatment (1h05 reporting delay, 22:55 cut-off, 15-minute grid with forward fill) and keeps only the ratio.

## What is not here, and why

The raw export is proprietary and is not distributed. It also contained customer-level fields that the model never used. The derived table holds **no monetary values**: the target is a ratio, and the closing-projection error can be computed from ratios alone (`projection / actual − 1 = actual share / predicted share − 1`), so every metric in the analysis is reproducible from this file.

## Reproducing

- To run the analysis: nothing to do. `analysis/01-forecast.Rmd` reads `intraday_fraction.csv`.
- To rebuild the table from a raw export: create `_local/config.R` as described at the top of `R/00_extract.R`, pointing `caminho_origem` to the folder with the export, and run the script. The raw file is read in place and never copied into the repository.
