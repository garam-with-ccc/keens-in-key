# Accuracy notes

Keens In Key has no ground-truth DJ library to train on, so its analyzers were tuned by
comparing against [Essentia](https://essentia.upf.edu) — `KeyExtractor` (EDMA and BGATE
profiles) and `RhythmExtractor2013` (multifeature) — on a local corpus of 177 files:

* 100 K-pop / pop 30-second previews (AAC, M4A)
* 71 AI-generated (Suno) songs, 1–2 minutes (MP3), many of them weakly tonal
* 6 mastered pop mixes (WAV)

Essentia is not ground truth either: its two key profiles agree with each other on only
85% of the same files, which is roughly the ceiling for this kind of comparison.

## Results (v0.1.0 defaults)

| Subset | n | Key exact | + relative | + neighbour (Camelot-compatible) | BPM within 2% | BPM half/double |
|---|---|---|---|---|---|---|
| All tracks | 177 | 63% | 69% | 77% | 72% | 5% |
| K-pop previews (M4A, 30 s) | 100 | 70% | 79% | 88% | 86% | 4% |
| Essentia confident (key strength ≥ 0.3 and both profiles agree) | 132 | 77% | 83% | 89% | 84% | 3% |
| Essentia confident tempo (confidence ≥ 1.5) | 125 | 70% | 78% | 87% | 90% | 3% |

"+ relative" counts the relative major/minor as a match (same Camelot number), and
"+ neighbour" additionally counts ±1 on the Camelot wheel, i.e. results a DJ could still
mix harmonically. Many of the remaining disagreements are on Suno tracks where Essentia
reports a key strength of 0 (no usable tonal content).

On synthetic test tracks with known key and tempo (chord loops with drums, see
`Tests/KeensInKeyCoreTests/AnalyzerTests.swift`) key and BPM are exact (BPM within ±0.1).

## What mattered

* **Harmonic reassignment.** A plain constant-Q chromagram over seven octaves picked the
  dominant key (one Camelot step up) far too often, because the third harmonic of every
  note lands on its fifth. Adding HPCP-style contributions of each bin to its sub-harmonics
  (weights 0.5 / 0.4 / 0.3 / 0.2 for harmonics 2–5) and limiting the range to C1–B5 raised
  exact agreement on confident tracks from 58% to 77%.
* **Tone profile.** Sha'ath's KeyFinder profile beat Krumhansl-Kessler, Temperley and the
  EDMA profile on this corpus; cosine similarity beat Pearson correlation.
* **Onset-envelope compression.** Decibel spectral flux lets quiet hi-hats (which hit every
  band) outweigh kicks, producing 3:2 tempo errors. Mapping band energies through
  `log(1 + μ·P/P₉₀)` before differencing keeps loud onsets dominant.
* **Harmonic support in tempo scoring.** Scoring a lag by `ac(L)·(1 + ac(2L) + 0.5·ac(4L))`
  prefers periods whose half-bar and bar multiples also fit, which suppresses the 4:3 errors
  caused by tresillo / dotted rhythms common in pop.
* **Tempo prior.** A log-normal prior centred on 125 BPM (σ = 0.9 octaves) with range folding
  into 70–175 BPM. Widening or moving the prior only added half/double errors.

## Confidence

The key confidence shown in the app is derived from the margin between the best and the
runner-up profile score; it was calibrated so that 40% ≈ coin flip between two candidates
and ≥ 90% means the runner-up is far behind. Tempo confidence combines the normalised
autocorrelation at the beat period with the regularity of the tracked beats.

## Reproducing

```bash
pip install essentia mutagen
swift build -c release --product kik
.build/release/kik analyze --json <files…>      # compare against essentia.standard.KeyExtractor / RhythmExtractor2013
```

`kik analyze` accepts the tuning flags used during the experiments (`--profile`,
`--similarity`, `--octaves`, `--harmonics`, `--tempo-flux`, `--tempo-harmonics`,
`--prior-bpm`, `--prior-sigma`, `--min-bpm`, `--max-bpm`).
