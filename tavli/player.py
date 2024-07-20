class Player:
    def __init__(self, name, color):
        self.name = name
        self.color = color
        self.checkers = []

    def make_move(self, board, from_point, to_point):
        if self.can_move(board, from_point, to_point):
            board.move_checker(from_point, to_point)

    def can_move(self, board, from_point, to_point):
        if from_point not in board.points or to_point not in board.points:
            return False
        if len(board.points[from_point]) == 0 or board.points[from_point][0] != self.color:
            return False
        return board.is_point_open(to_point) or (len(board.points[to_point]) == 1 and board.points[to_point][0] != self.color)
