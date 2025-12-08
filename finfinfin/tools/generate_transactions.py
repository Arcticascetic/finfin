#!/usr/bin/env python3
"""
Simple generator to create synthetic transactions for the finfinfin app.

Output format matches the app's SharedPreferences "transactions" string-list:
A JSON array of strings where each element is itself a JSON-encoded map:

[
  "{\"amount\": 12.34, \"type\": \"expense\", \"category\": \"Food\", \"date\": \"2025-11-20T12:34:56.000\"}",
  "...",
]

Usage:
  python3 generate_transactions.py --count 80000 --out transactions_sp_list.json

You can also run with smaller counts for testing:
  python3 generate_transactions.py --count 1000 --out sample.json

Notes:
- Dates are distributed over the last N years (configurable). Times are randomized to make each transaction unique.
- Amounts are generated with cents (two decimal places).
- Categories and types follow the app's defaults but are mixed.
"""

import argparse
import json
import random
from datetime import datetime, timedelta

DEFAULT_EXPENSE_CATEGORIES = [
    'Housing', 'Food', 'Transport', 'Utilities', 'Entertainment',
    'Health', 'Savings', 'Other Expense'
]

DEFAULT_INCOME_CATEGORIES = [
    'Salary', 'Investments', 'Gift', 'Rental Income', 'Other Income'
]


def random_date_within_years(years_back=3):
    """Return a random datetime within the last `years_back` years."""
    now = datetime.now()
    start = now - timedelta(days=365 * years_back)
    # pick random second between start and now
    delta = now - start
    rand_seconds = random.randint(0, int(delta.total_seconds()))
    return start + timedelta(seconds=rand_seconds)


def generate_transaction(i, years_back=5):
    """Create a synthetic transaction dict."""
    # decide type: bias slightly towards expenses
    ttype = 'expense' if random.random() < 0.75 else 'income'
    if ttype == 'expense':
        category = random.choice(DEFAULT_EXPENSE_CATEGORIES)
        # Expenses: smaller typical amounts
        amount = round(random.uniform(1.0, 500.0), 2)
    else:
        category = random.choice(DEFAULT_INCOME_CATEGORIES)
        amount = round(random.uniform(50.0, 5000.0), 2)

    # Add some deterministic-ish variation to make the data reproducible per index
    # but still random-looking
    dt = random_date_within_years(years_back)
    # Add micro-variation using the loop index so iso timestamp is unique
    dt = dt.replace(microsecond=(i * 13) % 1000000)
    # Make the timestamp explicit UTC (use Z) so other platforms parse it consistently.
    try:
        from datetime import timezone
        aware = dt.replace(tzinfo=timezone.utc)
        iso = aware.isoformat().replace('+00:00', 'Z')
    except Exception:
        iso = dt.isoformat()

    return {
        'amount': amount,
        'type': ttype,
        'category': category,
        'date': iso,
    }


def main():
    parser = argparse.ArgumentParser(description='Generate synthetic transactions for finfinfin')
    parser.add_argument('--count', type=int, default=80000, help='Number of transactions to generate (default: 80000)')
    parser.add_argument('--years', type=int, default=5, help='Spread dates across the last N years (default: 5)')
    parser.add_argument('--seed', type=int, default=None, help='Optional random seed for reproducibility')
    parser.add_argument('--out', type=str, default='transactions_sp_list.json', help='Output filename (JSON array of strings)')
    parser.add_argument('--jsonl', action='store_true', help='Also produce a newline-delimited file (same-data, one JSON string per line)')
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    out_list = []
    for i in range(args.count):
        tx = generate_transaction(i, years_back=args.years)
        # The app expects each list item to be a JSON-encoded map string
        out_list.append(json.dumps(tx))
        if (i + 1) % 5000 == 0:
            print(f'Generated {i+1} transactions...')

    # Write the shared-preferences-style JSON array of strings
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(out_list, f)

    print(f'Wrote {len(out_list)} transaction entries to {args.out}')

    if args.jsonl:
        lines_path = args.out + '.ndjson'
        with open(lines_path, 'w', encoding='utf-8') as f:
            for s in out_list:
                f.write(s + '\n')
        print(f'Also wrote newline-delimited JSON (one JSON string per line) to {lines_path}')


if __name__ == '__main__':
    main()
