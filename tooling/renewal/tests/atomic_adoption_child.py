"""Interruptible atomic-publication fixture; no device or account access."""
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from renew import atomic_exchange

first, second = Path(sys.argv[1]), Path(sys.argv[2])
if sys.argv[3] == "after":
    atomic_exchange(first, second)
print("ready", flush=True)
time.sleep(60)
