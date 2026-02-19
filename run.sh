#!/bin/bash

# Check for a command-line argument
if [ -z "$1" ]; then
    echo "Usage: ./run.sh [train|play]"
    exit 1
fi

# Run the appropriate command within the nix environment
if [ "$1" == "train" ]; then
    echo "Starting AI training..."
    nix-shell --run "python3 main.py train" | tee training_log_td.txt
elif [ "$1" == "play" ]; then
    echo "Starting interactive game..."
    nix-shell --run "python3 main.py play"
else
    echo "Invalid argument: $1"
    echo "Usage: ./run.sh [train|play]"
    exit 1
fi
