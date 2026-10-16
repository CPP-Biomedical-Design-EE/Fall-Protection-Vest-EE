"""Run the shared analyzer in UNIVRFall mode."""
import sys

from analyze_kfall import main


if "--dataset-kind" not in sys.argv:
    sys.argv[1:1] = ["--dataset-kind", "univrfall"]

main()
