import os
import sys

# Ensure repo root is on sys.path for test imports like `domain.*`.
_repo_root = os.path.abspath(os.path.dirname(__file__))
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

