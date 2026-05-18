WHITE: int = 1
BLACK: int = -1

_NAMES = {WHITE: "W", BLACK: "B", 0: "."}


def color_name(c: int) -> str:
    return _NAMES[c]


def other(c: int) -> int:
    return -c
