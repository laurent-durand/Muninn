\ src/micro/muninn.fs
\ Muninn micro scripting — Forth (gforth).
\ Reads metric values from shared memory (or stdin tokens) and evaluates
\ simple threshold expressions. Forth is used here for its near-zero footprint
\ on embedded / constrained targets where Python or Lua would be too heavy.

\ ─── Variable store ────────────────────────────────────────────────────────────
\ We store metrics as 16.16 fixed-point integers (value * 65536)

VARIABLE cpu-fp     \ CPU % as fixed-point
VARIABLE mem-fp     \ mem used % as fixed-point
VARIABLE load1-fp   \ load average (1m) as fixed-point
VARIABLE swap-fp    \ swap used % as fixed-point

\ Fixed-point scale factor
65536 CONSTANT FP-SCALE

: >fp  ( n -- fp )  FP-SCALE *  ;       \ integer → fixed-point
: fp>  ( fp -- n )  FP-SCALE /  ;       \ fixed-point → integer (truncate)
: fp*  ( a b -- c ) FP-SCALE / *  ;     \ multiply two fixed-point numbers

\ ─── Threshold words ─────────────────────────────────────────────────────────

: above?  ( fp threshold-int -- flag )
  >fp >  ;

: below?  ( fp threshold-int -- flag )
  >fp <  ;

\ ─── Severity output ──────────────────────────────────────────────────────────

: emit-alert  ( addr len severity-addr severity-len msg-addr msg-len -- )
  ." {" CR
  ."   \"severity\": \"" TYPE ." \"," CR
  ."   \"message\": \""  TYPE ." \"" CR
  ." }" CR  ;

\ ─── Rule evaluation ──────────────────────────────────────────────────────────

: check-cpu-warn ( -- )
  cpu-fp @ 70 above? IF
    S" warn"
    S" CPU utilisation above 70%"
    emit-alert
  THEN  ;

: check-cpu-crit ( -- )
  cpu-fp @ 90 above? IF
    S" crit"
    S" CPU utilisation above 90%"
    emit-alert
  THEN  ;

: check-mem-crit ( -- )
  mem-fp @ 90 above? IF
    S" crit"
    S" Memory usage above 90%"
    emit-alert
  THEN  ;

: check-load ( -- )
  load1-fp @ 8 above? IF
    S" warn"
    S" Load average above 8"
    emit-alert
  THEN  ;

: check-swap ( -- )
  swap-fp @ 70 above? IF
    S" warn"
    S" Swap usage above 70%"
    emit-alert
  THEN  ;

: evaluate-all ( -- )
  check-cpu-warn
  check-cpu-crit
  check-mem-crit
  check-load
  check-swap  ;

\ ─── Input parsing ────────────────────────────────────────────────────────────
\ Expects stdin tokens: cpu <n> mem <n> load1 <n> swap <n>
\ where <n> is percentage * 100 (i.e. 7523 = 75.23%)

: parse-token ( -- )
  BL WORD COUNT
  2DUP S" cpu"   COMPARE 0= IF 2DROP NUMBER DROP >fp cpu-fp   ! EXIT THEN
  2DUP S" mem"   COMPARE 0= IF 2DROP NUMBER DROP >fp mem-fp   ! EXIT THEN
  2DUP S" load1" COMPARE 0= IF 2DROP NUMBER DROP >fp load1-fp ! EXIT THEN
  2DUP S" swap"  COMPARE 0= IF 2DROP NUMBER DROP >fp swap-fp  ! EXIT THEN
  2DUP S" eval"  COMPARE 0= IF 2DROP evaluate-all             EXIT THEN
  2DROP  ;   \ unknown token — skip

: main-loop ( -- )
  BEGIN
    parse-token
  KEY? 0= UNTIL  ;

\ ─── Bootstrap ────────────────────────────────────────────────────────────────
CR ." muninn-micro v0.1.0 — Forth alert engine" CR
main-loop
BYE
