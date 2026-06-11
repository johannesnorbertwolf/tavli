#!/bin/bash

# Check for a command-line argument
if [ -z "$1" ]; then
    echo "Usage: ./run.sh [train [num_epochs]|play [network]|eval-random [games_per_color] [network]|eval-gold [games_per_color] [gold_version|gold_model_path] [network]|eval-gold-stats [x]|eval-gold-graph [x]|human-stats|human-graph [last_x]]"
    exit 1
fi

# Determine how to run Python (prefer .venv, then nix-shell, then system python)
PY_RUNNER=""
if [ -x ".venv/bin/python" ]; then
    PY_RUNNER=".venv/bin/python"
elif command -v nix-shell >/dev/null 2>&1; then
    PY_RUNNER="nix-shell --run \"python3\""
elif command -v python3 >/dev/null 2>&1; then
    PY_RUNNER="python3"
else
    echo "No suitable Python found. Please create a venv or install python3."
    exit 1
fi

# Run the appropriate command
if [ "$1" == "train" ]; then
    NUM_EPOCHS="$2"
    echo "Starting AI training..."
    if command -v caffeinate >/dev/null 2>&1; then
        RUNNER="caffeinate -dimsu"
    else
        RUNNER=""
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$NUM_EPOCHS" ]; then
            $RUNNER $PY_RUNNER main.py train "$NUM_EPOCHS" | tee training_log_td.txt
        else
            $RUNNER $PY_RUNNER main.py train | tee training_log_td.txt
        fi
    else
        if [ -n "$NUM_EPOCHS" ]; then
            $RUNNER nix-shell --run "python3 main.py train $NUM_EPOCHS" | tee training_log_td.txt
        else
            $RUNNER nix-shell --run "python3 main.py train" | tee training_log_td.txt
        fi
    fi
elif [ "$1" == "play" ]; then
    NETWORK_ARG="${2:-}"
    echo "Starting interactive game..."
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$NETWORK_ARG" ]; then
            $PY_RUNNER main.py play --network "$NETWORK_ARG"
        else
            $PY_RUNNER main.py play
        fi
    else
        if [ -n "$NETWORK_ARG" ]; then
            nix-shell --run "python3 main.py play --network $NETWORK_ARG"
        else
            nix-shell --run "python3 main.py play"
        fi
    fi
elif [ "$1" == "eval-random" ]; then
    GAMES_PER_COLOR="${2:-100}"
    NETWORK_ARG="${3:-}"
    echo "Evaluating AI against random ($GAMES_PER_COLOR games per color)..."
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$NETWORK_ARG" ]; then
            $PY_RUNNER main.py eval-random "$GAMES_PER_COLOR" --network "$NETWORK_ARG"
        else
            $PY_RUNNER main.py eval-random "$GAMES_PER_COLOR"
        fi
    else
        if [ -n "$NETWORK_ARG" ]; then
            nix-shell --run "python3 main.py eval-random $GAMES_PER_COLOR --network $NETWORK_ARG"
        else
            nix-shell --run "python3 main.py eval-random $GAMES_PER_COLOR"
        fi
    fi
elif [ "$1" == "eval-gold" ]; then
    GAMES_PER_COLOR="${2:-100}"
    GOLD_ARG="${3:-}"
    NETWORK_ARG="${4:-}"
    GOLD_MODEL_PATH=""

    # Allow passing network without gold arg:
    #   ./run.sh eval-gold 100 cnn
    if [ -z "$NETWORK_ARG" ] && { [ "$GOLD_ARG" = "mlp" ] || [ "$GOLD_ARG" = "cnn" ]; }; then
        NETWORK_ARG="$GOLD_ARG"
        GOLD_ARG=""
    fi

    # Optional argument supports either:
    # - explicit model path (e.g. models/gold_v1.pth)
    # - version shorthand (e.g. 1, 2, v1, v2) -> models/gold_v<version>.pth
    if [ -n "$GOLD_ARG" ]; then
        if [[ "$GOLD_ARG" == */* ]] || [[ "$GOLD_ARG" == *.pth ]]; then
            GOLD_MODEL_PATH="$GOLD_ARG"
        else
            GOLD_VERSION="${GOLD_ARG#v}"
            if [[ "$GOLD_VERSION" =~ ^[0-9]+$ ]]; then
                GOLD_MODEL_PATH="models/gold_v${GOLD_VERSION}.pth"
            else
                echo "Invalid gold version/path: '$GOLD_ARG'"
                echo "Use version like '1' or 'v1', or a model path like 'models/gold_v1.pth'."
                exit 1
            fi
        fi
    fi

    if [ -n "$GOLD_MODEL_PATH" ]; then
        echo "Evaluating AI against gold ($GAMES_PER_COLOR games per color, gold: $GOLD_MODEL_PATH)..."
    else
        echo "Evaluating AI against gold ($GAMES_PER_COLOR games per color, gold path from config)..."
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$GOLD_MODEL_PATH" ]; then
            if [ -n "$NETWORK_ARG" ]; then
                $PY_RUNNER main.py eval-gold "$GAMES_PER_COLOR" "$GOLD_MODEL_PATH" --network "$NETWORK_ARG"
            else
                $PY_RUNNER main.py eval-gold "$GAMES_PER_COLOR" "$GOLD_MODEL_PATH"
            fi
        else
            if [ -n "$NETWORK_ARG" ]; then
                $PY_RUNNER main.py eval-gold "$GAMES_PER_COLOR" --network "$NETWORK_ARG"
            else
                $PY_RUNNER main.py eval-gold "$GAMES_PER_COLOR"
            fi
        fi
    else
        if [ -n "$GOLD_MODEL_PATH" ]; then
            if [ -n "$NETWORK_ARG" ]; then
                nix-shell --run "python3 main.py eval-gold $GAMES_PER_COLOR $GOLD_MODEL_PATH --network $NETWORK_ARG"
            else
                nix-shell --run "python3 main.py eval-gold $GAMES_PER_COLOR $GOLD_MODEL_PATH"
            fi
        else
            if [ -n "$NETWORK_ARG" ]; then
                nix-shell --run "python3 main.py eval-gold $GAMES_PER_COLOR --network $NETWORK_ARG"
            else
                nix-shell --run "python3 main.py eval-gold $GAMES_PER_COLOR"
            fi
        fi
    fi
elif [ "$1" == "eval-gold-stats" ]; then
    LAST_X="${2:-50}"
    echo "Analyzing eval-vs-gold history (last $LAST_X eval points)..."
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        $PY_RUNNER main.py eval-gold-stats "$LAST_X"
    else
        nix-shell --run "python3 main.py eval-gold-stats $LAST_X"
    fi
elif [ "$1" == "eval-gold-graph" ]; then
    LAST_X="${2:-}"
    if [ -n "$LAST_X" ]; then
        echo "Generating eval-vs-gold graph (last $LAST_X eval points)..."
    else
        echo "Generating eval-vs-gold graph (all eval points)..."
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$LAST_X" ]; then
            $PY_RUNNER main.py eval-gold-graph "$LAST_X"
        else
            $PY_RUNNER main.py eval-gold-graph
        fi
    else
        if [ -n "$LAST_X" ]; then
            nix-shell --run "python3 main.py eval-gold-graph $LAST_X"
        else
            nix-shell --run "python3 main.py eval-gold-graph"
        fi
    fi
elif [ "$1" == "eval-lookahead" ]; then
    TOTAL_GAMES="${2:-1000}"
    WORKERS_ARG=""
    if [ "$3" == "--workers" ] && [ -n "$4" ]; then
        WORKERS_ARG="--workers $4"
    fi
    echo "Validating flexible lookahead vs fixed 2-ply ($TOTAL_GAMES games total)..."
    if command -v caffeinate >/dev/null 2>&1; then
        RUNNER="caffeinate -dimsu"
    else
        RUNNER=""
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        $RUNNER $PY_RUNNER main.py eval-lookahead "$TOTAL_GAMES" $WORKERS_ARG
    else
        $RUNNER nix-shell --run "python3 main.py eval-lookahead $TOTAL_GAMES $WORKERS_ARG"
    fi
elif [ "$1" == "rollout-lab" ]; then
    shift
    echo "Rollout lab: disagreement mining + rollout-labeled fine-tune..."
    if command -v caffeinate >/dev/null 2>&1; then
        RUNNER="caffeinate -dimsu"
    else
        RUNNER=""
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        $RUNNER $PY_RUNNER main.py rollout-lab "$@"
    else
        $RUNNER nix-shell --run "python3 main.py rollout-lab $*"
    fi
elif [ "$1" == "human-stats" ]; then
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        $PY_RUNNER main.py human-stats
    else
        nix-shell --run "python3 main.py human-stats"
    fi
elif [ "$1" == "human-graph" ]; then
    LAST_X="${2:-}"
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        if [ -n "$LAST_X" ]; then
            $PY_RUNNER main.py human-graph "$LAST_X"
        else
            $PY_RUNNER main.py human-graph
        fi
    else
        if [ -n "$LAST_X" ]; then
            nix-shell --run "python3 main.py human-graph $LAST_X"
        else
            nix-shell --run "python3 main.py human-graph"
        fi
    fi
elif [ "$1" == "tournament" ]; then
    NUM_RUNS="${2:-100}"
    SEED="${3:-}"
    echo "Running round-robin tournament ($NUM_RUNS runs)..."
    ARGS="--num-runs $NUM_RUNS"
    if [ -n "$SEED" ]; then
        ARGS="$ARGS --seed $SEED"
    fi
    if [ "$PY_RUNNER" = ".venv/bin/python" ] || [ "$PY_RUNNER" = "python3" ]; then
        $PY_RUNNER main.py tournament $ARGS | tee tournament_log.txt
    else
        nix-shell --run "python3 main.py tournament $ARGS" | tee tournament_log.txt
    fi
else
    echo "Invalid argument: $1"
    echo "Usage: ./run.sh [train [num_epochs]|play [network]|eval-random [games_per_color] [network]|eval-gold [games_per_color] [gold_version|gold_model_path] [network]|eval-gold-stats [x]|eval-gold-graph [x]|human-stats|human-graph [last_x]|tournament [num_runs] [seed]]"
    exit 1
fi
