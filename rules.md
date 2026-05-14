# Plakoto Rules

Plakoto is a Greek backgammon variant. If you know backgammon, the key differences are: all checkers start on one point, there is no hitting/bar, and you pin instead.

## Setup

- 24 points, numbered 1–24.
- **White**: all 15 checkers start on point 1, moves toward point 24.
- **Black**: all 15 checkers start on point 24, moves toward point 1.
- Black moves first.

## Movement

Roll two dice. Move one or two checkers, one per die. Both dice must be used if legally possible; if only one can be played, play it. You choose which die to play first; if your first choice makes the second die unplayable, the turn ends after one die — even if a different first choice would have allowed both.

**Doubles**: play the die value four times.

**Combining dice**: both dice may be spent on a single checker (moving it the sum), provided at least one intermediate square (die1-steps or die2-steps from the start) is open.

## Landing

| Destination | Legal? |
|---|---|
| Empty point | Yes |
| Own checkers | Yes |
| Single opponent checker | Yes — **pins** it (see below) |
| Two or more opponent checkers | No — blocked |
| Point where opponent has pinned your checker | No — blocked |

## Pinning (replaces hitting)

There is no bar. When you land on a lone opponent checker, it is **pinned** underneath yours and cannot move until you vacate that point.

- You may stack further own checkers on a pinned point.

## Home Board and Bearing Off

**Home board**: points 19–24 for White; points 1–6 for Black.

You may only bear off when **all** your checkers are in your home board. To bear off, the die must equal the exact distance from the checker to the off-board slot — there is no overshooting. A checker can enter the home board and bear off in the same turn if it uses both dice and no checkers remain outside home after entering.

## Winning

You win if either condition is met:

1. **Bear off all 15 checkers.**
2. **Pin trap**: you pin the last remaining opponent checker that is still on its starting point (point 24 for Black, point 1 for White). This wins immediately.
