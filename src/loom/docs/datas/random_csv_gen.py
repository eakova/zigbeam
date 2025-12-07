import argparse
from pathlib import Path
from typing import Optional, Union
import time

import numpy as np

try:
    import pandas as pd
except ImportError:
    pd = None

DEFAULT_OUTPUT = Path(__file__).resolve().parent / "inputs" / "sample_01.csv"


def generate_csv(
    filename: Union[Path, str] = DEFAULT_OUTPUT,
    total_rows: int = 100_000,
    chunk_size: int = 10_000,
    seed: Optional[int] = None,
    prefer_pandas: bool = True,
) -> None:
    if total_rows <= 0:
        raise ValueError("total_rows must be positive")
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")

    if seed is not None:
        np.random.seed(seed)

    filename = Path(filename)
    filename.parent.mkdir(parents=True, exist_ok=True)

    print(f"Generating {total_rows} rows into {filename}...")
    start_time = time.time()
    use_pandas = prefer_pandas and pd is not None
    if prefer_pandas and pd is None:
        print("pandas not installed; falling back to numpy writer.")

    single_words = ['Apple', 'Banana', 'Cherry', 'Date', 'Elderberry', 'Fig', 'Grape', 'Honeydew']
    multi_words = [
        'lorem ipsum dolor', 'sit amet consectetur', 'adipiscing elit',
        'sed do eiusmod', 'tempor incididunt', 'ut labore et dolore',
        'magna aliqua', 'ut enim ad minim'
    ]
    header = ['id', 'measurement', 'category', 'description', 'is_active']

    with filename.open('w') as f:
        f.write(','.join(header) + '\n')

        for i in range(0, total_rows, chunk_size):
            current_chunk_size = min(chunk_size, total_rows - i)

            ids = np.arange(i, i + current_chunk_size)
            measurements = np.random.uniform(0.0, 1000.0, size=current_chunk_size).round(4)
            categories = np.random.choice(single_words, size=current_chunk_size)
            descriptions = np.random.choice(multi_words, size=current_chunk_size)
            is_active = np.random.randint(0, 2, size=current_chunk_size)

            if use_pandas:
                df = pd.DataFrame({
                    'id': ids,
                    'measurement': measurements,
                    'category': categories,
                    'description': descriptions,
                    'is_active': is_active
                })
                df.to_csv(f, header=False, index=False, mode='a')
            else:
                stacked = np.column_stack((ids, measurements, categories, descriptions, is_active))
                np.savetxt(f, stacked, delimiter=",", fmt="%s")
            print(f"Written {i + current_chunk_size:,} rows... ({time.time() - start_time:.2f}s elapsed)")

    approx_size_mb = total_rows / 1_000_000 * 50
    print(f"Done! File saved as {filename}. Approx size: {approx_size_mb:.2f} MB")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a sample CSV for LOOM demos.")
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_OUTPUT, help="Output CSV path.")
    parser.add_argument("--total-rows", type=int, default=100_000, help="Total number of rows to generate.")
    parser.add_argument("--chunk-size", type=int, default=10_000, help="Rows per write chunk.")
    parser.add_argument("--seed", type=int, default=None, help="Optional random seed for reproducibility.")
    parser.add_argument(
        "--no-pandas",
        action="store_true",
        help="Force numpy writer even if pandas is installed.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    generate_csv(
        filename=args.output,
        total_rows=args.total_rows,
        chunk_size=args.chunk_size,
        seed=args.seed,
        prefer_pandas=not args.no_pandas,
    )
