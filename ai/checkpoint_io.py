import os
from typing import Dict, Any, Tuple, Optional

import torch

NETWORK_TYPE = "mlp"
ENCODER_VERSION_LEGACY = "legacy_unary_v1"
ENCODER_VERSION_CURRENT = "unary_v3"
HIDDEN_SIZES_LEGACY = [512, 256, 128]


def _is_metadata_checkpoint(obj: Any) -> bool:
    return isinstance(obj, dict) and "state_dict" in obj


def _migrate_state_dict(state_dict: Dict[str, torch.Tensor]) -> Dict[str, torch.Tensor]:
    """Remap legacy fc1/fc2/fc3/fc4 keys to layers.N format."""
    if not any(k.startswith("fc") for k in state_dict):
        return state_dict
    mapping = {"fc1": "layers.0", "fc2": "layers.1", "fc3": "layers.2", "fc4": "layers.3"}
    return {
        mapping.get(k.split(".")[0], k.split(".")[0]) + "." + ".".join(k.split(".")[1:]): v
        for k, v in state_dict.items()
    }


def _board_spec_from_config(config) -> Dict[str, int]:
    return {
        "board_size": int(config.get_board_size()),
        "pieces_per_player": int(config.get_pieces_per_player()),
        "home_size": int(config.get_home_size()),
    }


def load_state_dict(path: str, device: Optional[torch.device] = None) -> Tuple[Dict[str, torch.Tensor], Dict[str, Any]]:
    if device is None:
        device = torch.device("cpu")
    if not os.path.exists(path):
        raise FileNotFoundError(path)

    obj = torch.load(path, map_location=device, weights_only=True)
    HIDDEN_SIZES_LEGACY = [512, 256, 128]

    if _is_metadata_checkpoint(obj):
        meta = {
            "network_type": obj.get("network_type", NETWORK_TYPE),
            "encoder_version": obj.get("encoder_version", ENCODER_VERSION_LEGACY),
            "hidden_sizes": obj.get("hidden_sizes", HIDDEN_SIZES_LEGACY),
            "board_spec": obj.get("board_spec", {}),
        }
        return _migrate_state_dict(obj["state_dict"]), meta

    # Legacy plain state_dict
    meta = {
        "network_type": NETWORK_TYPE,
        "encoder_version": ENCODER_VERSION_LEGACY,
        "hidden_sizes": HIDDEN_SIZES_LEGACY,
        "board_spec": {},
    }
    return _migrate_state_dict(obj), meta


def save_checkpoint(path: str, evaluator, config) -> None:
    payload = {
        "state_dict": evaluator.state_dict(),
        "network_type": NETWORK_TYPE,
        "encoder_version": ENCODER_VERSION_CURRENT,
        "hidden_sizes": evaluator.hidden_sizes,
        "board_spec": _board_spec_from_config(config),
    }
    torch.save(payload, path)


def load_agent_from_checkpoint(path: str, config, device: Optional[torch.device] = None):
    from ai.board_evaluator import BoardEvaluator
    from ai.board_encoder import BoardEncoder
    from ai.agent import Agent

    if device is None:
        device = torch.device("cpu")
    state_dict, meta = load_state_dict(path, device=device)
    encoder = BoardEncoder(config, version=meta["encoder_version"])
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=meta["hidden_sizes"]).to(device)
    evaluator.load_state_dict(state_dict)
    evaluator.eval()
    return Agent(evaluator, encoder), meta
