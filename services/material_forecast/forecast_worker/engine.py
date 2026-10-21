"""Bounded CPU forecasts, selection and independent chronological validation."""

from __future__ import annotations

import math
import warnings
from dataclasses import dataclass
from datetime import datetime
from importlib.metadata import version
from statistics import mean

import pandas as pd
from statsforecast import StatsForecast
from statsforecast.models import AutoETS, AutoTheta, Naive, RandomWalkWithDrift

from . import __version__
from .data import Dataset, Revision, utc_text

HORIZONS = (1, 5, 20)
MIN_HISTORY = 120
MIN_SELECTION_FOLDS = 4
MIN_VALIDATION_FOLDS = 20
MAX_SELECTION_FOLDS = 8
MAX_VALIDATION_FOLDS = 30
MAX_TRAINING_ROWS = 1000
COVERAGE_FLOOR = 0.70
CANDIDATES = ("RandomWalkWithDrift", "AutoETS", "AutoTheta")


@dataclass(frozen=True)
class Estimate:
    price: float
    lower: float
    upper: float


@dataclass(frozen=True)
class Fold:
    origin: Revision
    history: tuple[Revision, ...]
    targets: tuple[Revision, ...]


def decimal_text(value: float) -> str:
    if not math.isfinite(value):
        raise ValueError("non-finite forecast metric")
    return format(value, ".18f").rstrip("0").rstrip(".") or "0"


def model_for(name: str):
    if name == "Naive":
        return Naive(alias=name)
    if name == "RandomWalkWithDrift":
        return RandomWalkWithDrift(alias=name)
    if name == "AutoETS":
        return AutoETS(season_length=1, alias=name)
    if name == "AutoTheta":
        return AutoTheta(season_length=1, alias=name)
    raise ValueError("unknown model")


def forecast(history: tuple[Revision, ...] | list[Revision], names: tuple[str, ...]) -> dict[str, dict[int, Estimate]]:
    """No dates are invented. Integer ds means next *observations*, not calendar days."""
    values = [float(row.price) for row in history[-MAX_TRAINING_ROWS:]]
    frame = pd.DataFrame({"unique_id": "benchmark", "ds": range(len(values)), "y": values})
    worker = StatsForecast(models=[model_for(name) for name in names], freq=1, n_jobs=1)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        output = worker.forecast(df=frame, h=max(HORIZONS), level=[80])
    result: dict[str, dict[int, Estimate]] = {}
    for name in names:
        predictions = {}
        for horizon in HORIZONS:
            row = output.iloc[horizon - 1]
            point, lower, upper = (float(row[column]) for column in (name, name + "-lo-80", name + "-hi-80"))
            # Failed fits/invalid intervals are never turned into an apparently valid signal.
            if not all(math.isfinite(value) for value in (point, lower, upper)) or lower <= 0 or lower > point or point > upper:
                raise ValueError("model produced an invalid prediction interval")
            predictions[horizon] = Estimate(point, lower, upper)
        result[name] = predictions
    return result


def chronological_folds(dataset: Dataset) -> list[Fold]:
    first = dataset.first_publications
    days = sorted(first)
    folds = []
    # All origins are separated by 20 observations: their target blocks do not overlap.
    origin_indices = list(range(MIN_HISTORY - 1, len(days) - max(HORIZONS), max(HORIZONS)))
    origin_indices = origin_indices[-2 * (MAX_SELECTION_FOLDS + MAX_VALIDATION_FOLDS):]
    earliest_later_publication = [None] * len(days)
    earliest = None
    for index in range(len(days) - 1, -1, -1):
        earliest_later_publication[index] = earliest
        publication = first[days[index]].available_at
        earliest = publication if earliest is None else min(earliest, publication)
    for origin_index in origin_indices:
        origin = first[days[origin_index]]
        if earliest_later_publication[origin_index] <= origin.available_at:
            continue
        history = dataset.as_of(origin.available_at, through=origin.day)
        targets = tuple(first[days[origin_index + horizon]] for horizon in HORIZONS)
        if len(history) < MIN_HISTORY:
            continue
        # A late publication must not forecast a price already public at that instant.
        folds.append(Fold(origin, tuple(history[-MAX_TRAINING_ROWS:]), targets))
    return folds[-(MAX_SELECTION_FOLDS + MAX_VALIDATION_FOLDS):]


def horizon_scores(records: list[tuple[Fold, dict[int, Estimate]]]) -> dict[int, dict[str, float]]:
    scores = {}
    for index, horizon in enumerate(HORIZONS):
        errors, covered = [], []
        for fold, estimates in records:
            truth = float(fold.targets[index].price)
            prediction = estimates[horizon]
            errors.append(abs(truth - prediction.price))
            covered.append(float(prediction.lower <= truth <= prediction.upper))
        scores[horizon] = {"mae": mean(errors), "coverage": mean(covered)}
    return scores


def evaluate_model(folds: list[Fold], name: str) -> list[tuple[Fold, dict[int, Estimate]]]:
    return [(fold, forecast(fold.history, (name,))[name]) for fold in folds]


def validation_reasons(model_scores: dict, naive_scores: dict) -> list[str]:
    """Do not let an easy short horizon hide a bad procurement horizon."""
    reasons = []
    if any(model_scores[h]["mae"] >= naive_scores[h]["mae"] for h in HORIZONS):
        reasons.append("VALIDATION_NOT_BETTER_THAN_NAIVE")
    if any(model_scores[h]["coverage"] < COVERAGE_FLOOR for h in HORIZONS):
        reasons.append("INTERVAL_COVERAGE_BELOW_THRESHOLD")
    return reasons


def build_snapshot(dataset: Dataset, now: datetime) -> dict:
    current = dataset.as_of(now)
    snapshot = {
        "schemaVersion": 1,
        **{key: value for key, value in dataset.manifest.items() if key != "synthetic"},
        "dataAsOf": current[-1].day.isoformat() if current else None,
        "generatedAt": utc_text(now),
        "latestPrice": format(current[-1].price, "f") if current else None,
        "status": "INSUFFICIENT", "reasonCodes": [],
        "modelVersion": "Naive/worker-" + __version__,
        "libraryVersion": version("statsforecast"),
        "datasetDigest": dataset.digest,
        "validation": {
            "passed": False, "baselineMAE": None, "modelMAE": None, "folds": 0,
            "coverage80": None, "backtestStart": None, "backtestEnd": None,
        },
        "forecasts": [], "procurementSignal": "INSUFFICIENT",
    }
    if dataset.manifest.get("synthetic", False):
        snapshot["synthetic"] = True
    if len(current) < 2:
        snapshot["reasonCodes"] = ["INSUFFICIENT_OBSERVATIONS"]
        return snapshot

    snapshot["status"] = "BASELINE_ONLY"
    final_name = "Naive"
    chosen = None
    folds = chronological_folds(dataset)
    selection_count = min(MAX_SELECTION_FOLDS, len(folds) - MIN_VALIDATION_FOLDS)
    if selection_count < MIN_SELECTION_FOLDS:
        snapshot["reasonCodes"].append("INSUFFICIENT_BACKTEST_FOLDS")
    else:
        selection_folds, validation_folds = folds[:selection_count], folds[selection_count:]
        # Model choice may only consume labels published by the first validation origin.
        # Delayed labels cannot travel back in time, even when the CSV was imported today.
        selection_cutoff = validation_folds[0].origin.available_at
        selection_folds = [fold for fold in selection_folds
                           if all(target.available_at <= selection_cutoff for target in fold.targets)]
        if len(selection_folds) < MIN_SELECTION_FOLDS:
            snapshot["reasonCodes"].append("SELECTION_LABELS_NOT_AVAILABLE")
        candidate_scores: dict[str, float] = {}
        for name in CANDIDATES if len(selection_folds) >= MIN_SELECTION_FOLDS else ():
            try:
                scores = horizon_scores(evaluate_model(selection_folds, name))
                candidate_scores[name] = mean(score["mae"] for score in scores.values())
            except (ValueError, ArithmeticError, RuntimeError):
                # A bad candidate cannot stop a valid baseline from being published.
                continue
        if not candidate_scores:
            snapshot["reasonCodes"].append("CANDIDATE_MODELS_UNAVAILABLE")
        else:
            chosen = min(candidate_scores, key=candidate_scores.get)
            try:
                model_scores = horizon_scores(evaluate_model(validation_folds, chosen))
                naive_scores = horizon_scores(evaluate_model(validation_folds, "Naive"))
                validation = snapshot["validation"]
                validation.update({
                    "baselineMAE": decimal_text(mean(score["mae"] for score in naive_scores.values())),
                    "modelMAE": decimal_text(mean(score["mae"] for score in model_scores.values())),
                    "folds": len(validation_folds),
                    "coverage80": decimal_text(mean(score["coverage"] for score in model_scores.values())),
                    "backtestStart": validation_folds[0].origin.day.isoformat(),
                    "backtestEnd": max(target.day for target in validation_folds[-1].targets).isoformat(),
                })
                # Every horizon must beat its own Naive baseline; pooling cannot hide a failure.
                snapshot["reasonCodes"].extend(validation_reasons(model_scores, naive_scores))
                validation["passed"] = not snapshot["reasonCodes"]
                if validation["passed"]:
                    final_name = chosen
                    snapshot["status"] = "READY"
            except (ValueError, ArithmeticError, RuntimeError):
                snapshot["reasonCodes"].append("VALIDATION_MODEL_FAILED")

    try:
        predictions = forecast(current, (final_name,))[final_name]
    except (ValueError, ArithmeticError, RuntimeError):
        # Recheck the chosen model on the actual latest window; a validation pass is insufficient.
        snapshot["reasonCodes"].append("LATEST_MODEL_FAILED")
        snapshot["validation"]["passed"] = False
        snapshot["status"] = "BASELINE_ONLY"
        final_name = "Naive"
        try:
            predictions = forecast(current, (final_name,))[final_name]
        except (ValueError, ArithmeticError, RuntimeError):
            snapshot["status"] = "INSUFFICIENT"
            snapshot["reasonCodes"].append("BASELINE_MODEL_FAILED")
            return snapshot

    snapshot["modelVersion"] = final_name + "/worker-" + __version__
    if chosen and chosen != final_name:
        snapshot["modelVersion"] += ";candidate=" + chosen
    latest = float(current[-1].price)
    for horizon in HORIZONS:
        estimate = predictions[horizon]
        direction = "UNCERTAIN"
        if snapshot["status"] == "READY":
            if estimate.lower > latest:
                direction = "UP"
            elif estimate.upper < latest:
                direction = "DOWN"
        snapshot["forecasts"].append({
            "horizon": horizon, "price": decimal_text(estimate.price),
            "lower80": decimal_text(estimate.lower), "upper80": decimal_text(estimate.upper),
            "direction": direction,
        })
    if snapshot["status"] == "READY":
        no_down = all(item["direction"] != "DOWN" for item in snapshot["forecasts"])
        longer_up = any(item["direction"] == "UP" and item["horizon"] in (5, 20)
                        for item in snapshot["forecasts"])
        snapshot["procurementSignal"] = "RISING" if no_down and longer_up else "WATCH"
    return snapshot
