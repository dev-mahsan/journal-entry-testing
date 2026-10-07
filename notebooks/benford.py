"""
benford.py
Step 5: Benford's Law analysis of journal entry amounts.

Reads the cleaned journal_entries table from PostgreSQL, runs:
  1. First-digit test on all amounts (does the ledger look natural overall?)
  2. First-two-digits test on manual entries (where do specific spikes sit?)
  3. Drill-down into the biggest spike, cross-checked with the SQL exceptions

Run from the project folder:  python notebooks/benford.py
"""

from getpass import getpass

import matplotlib
matplotlib.use("Agg")  # save charts to files, no pop-up windows
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

OUTPUT_DIR = "output"


# ------------------------------------------------------------------
# Load data
# ------------------------------------------------------------------
def load_data():
    password = getpass("PostgreSQL password: ")
    url = URL.create(
        "postgresql+psycopg2",
        username="postgres",
        password=password,  # URL.create handles special characters like @
        host="localhost",
        port=5432,
        database="je_testing",
    )
    engine = create_engine(url)

    # One amount per line: whichever side (debit or credit) is filled in.
    # Amounts under 10 have no meaningful first-two digits, so leave them out.
    lines = pd.read_sql(
        """
        SELECT je_id, line_no, source, posted_by,
               GREATEST(debit, credit) AS amount
        FROM journal_entries
        WHERE GREATEST(debit, credit) >= 10
        """,
        engine,
    )
    exceptions = pd.read_sql("SELECT test_id, je_id FROM je_exceptions", engine)
    return lines, exceptions


# ------------------------------------------------------------------
# Benford helpers
# ------------------------------------------------------------------
def leading_digits(amount, n):
    """First n digits of a number, e.g. leading_digits(4987.50, 2) -> 49."""
    return int(str(int(amount))[:n])


def benford_test(amounts, n_digits):
    """Compare observed leading-digit frequencies with Benford's expected ones."""
    digits = amounts.apply(leading_digits, n=n_digits)
    lo, hi = 10 ** (n_digits - 1), 10 ** n_digits - 1
    possible = range(lo, hi + 1)
    total = len(digits)

    table = pd.DataFrame(index=pd.Index(possible, name="digits"))
    table["count"] = digits.value_counts().reindex(possible, fill_value=0)
    table["observed"] = table["count"] / total
    table["expected"] = np.log10(1 + 1 / table.index.to_numpy())

    # Z-statistic: how unusual is each digit's gap, given the sample size?
    # (the 1/(2N) term is a standard continuity correction)
    p = table["expected"]
    gap = (table["observed"] - p).abs() - 1 / (2 * total)
    table["z"] = (gap.clip(lower=0) / np.sqrt(p * (1 - p) / total)).round(2)

    mad = (table["observed"] - table["expected"]).abs().mean()
    return table, mad, total


def conformity(mad, n_digits):
    """Nigrini's MAD thresholds for judging overall conformity."""
    limits = {1: (0.006, 0.012, 0.015), 2: (0.0012, 0.0018, 0.0022)}[n_digits]
    if mad <= limits[0]:
        return "Close conformity"
    if mad <= limits[1]:
        return "Acceptable conformity"
    if mad <= limits[2]:
        return "Marginal conformity"
    return "Nonconformity"


def plot(table, title, filename, highlight=()):
    fig, ax = plt.subplots(figsize=(12 if len(table) > 9 else 8, 5))
    colors = ["#c0392b" if d in highlight else "#2c3e50" for d in table.index]
    ax.bar(table.index, table["observed"], color=colors, label="Observed")
    ax.plot(table.index, table["expected"], color="#e67e22", linewidth=2, label="Benford expected")
    ax.set_title(title)
    ax.set_xlabel("Leading digit(s)")
    ax.set_ylabel("Proportion of amounts")
    ax.legend()
    fig.tight_layout()
    fig.savefig(f"{OUTPUT_DIR}/{filename}", dpi=120)
    plt.close(fig)


# ------------------------------------------------------------------
# Main analysis
# ------------------------------------------------------------------
def main():
    lines, exceptions = load_data()
    print(f"Loaded {len(lines)} amounts from {lines['je_id'].nunique()} journal entries\n")

    # Test 1: first digit, all amounts
    t1, mad1, n1 = benford_test(lines["amount"], 1)
    print("=== Test 1: First digit, all amounts ===")
    print(t1[["count", "observed", "expected", "z"]].round(3).to_string())
    print(f"\nN = {n1}   MAD = {mad1:.4f}   ->  {conformity(mad1, 1)}\n")
    plot(t1, "First-digit test: all journal entry amounts", "benford_first_digit.png")

    # Test 2: first two digits, manual entries only
    # Manual entries are where people (and fraud) come in; system entries
    # are automated and would dilute any human pattern.
    manual = lines[lines["source"] == "Manual"]
    t2, mad2, n2 = benford_test(manual["amount"], 2)
    spikes = t2[(t2["z"] > 2.57) & (t2["observed"] > t2["expected"])].sort_values("z", ascending=False)

    print("=== Test 2: First two digits, manual entries ===")
    print(f"N = {n2}   MAD = {mad2:.5f}   ->  {conformity(mad2, 2)}")
    print("\nDigit combinations appearing more than expected (z > 2.57, 99% confidence):")
    print(spikes[["count", "observed", "expected", "z"]].round(4).to_string())
    plot(t2, "First-two-digits test: manual entries (red = significant spike)",
         "benford_first_two_digits.png", highlight=set(spikes.index))

    # Drill-down: which entries make up the biggest spike?
    top = spikes.index[0]
    manual = manual.assign(first_two=manual["amount"].apply(leading_digits, n=2))
    drill = manual[manual["first_two"] == top].drop_duplicates("je_id")

    flagged = exceptions.groupby("je_id")["test_id"].apply(lambda s: ", ".join(sorted(set(s))))
    drill = drill.assign(sql_tests=drill["je_id"].map(flagged).fillna("-"))
    drill = drill.sort_values("amount", ascending=False)

    print(f"\n=== Drill-down: manual entries starting with {top} ===")
    print(drill[["je_id", "posted_by", "amount", "sql_tests"]].to_string(index=False))
    drill.to_csv(f"{OUTPUT_DIR}/benford_drilldown_{top}.csv", index=False)

    print(f"\nCharts and drill-down saved to the '{OUTPUT_DIR}' folder.")


if __name__ == "__main__":
    main()
