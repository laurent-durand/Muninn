! src/stack/muninn.factor
! Muninn stack-based processing — Factor.
! Factor's concatenative model and interactive image make it useful for
! exploratory metric analysis and live REPL-driven dashboarding.

USING: kernel io io.encodings.utf8 sequences math math.statistics
       math.order strings assocs json.reader json.writer
       prettyprint formatting calendar ;
IN: muninn.stack

! ─── Metric words ─────────────────────────────────────────────────────────────

! ( pct -- bar ) — ASCII bar 40 chars wide
: pct-bar ( pct -- bar )
    40 * 100 / round >integer
    [ "█" ] swap replicate concat
    40 over length - [ "░" ] swap replicate concat
    append ;

! ( v warn crit -- severity ) — returns "ok" "warn" or "crit"
: severity ( v warn crit -- severity )
    pick >= [ drop drop "crit" ]
    [ swap >= [ drop "warn" ] [ drop "ok" ] if ] if ;

! ( xs -- mean ) — arithmetic mean
: mean* ( xs -- mean )
    [ 0 [ + ] reduce ] [ length ] bi / ;

! ( xs -- sd ) — population standard deviation
: stddev* ( xs -- sd )
    dup mean* :> mu
    [ mu - sq ] map mean* sqrt ;

! ( xs p -- pct ) — p-th percentile (0-100), linear interpolation
: percentile* ( xs p -- result )
    swap natural-sort :> sorted
    sorted length 1 - :> n
    100 / n * :> idx_f
    idx_f truncate>integer :> lo
    lo 1 + n min :> hi
    idx_f lo - :> frac
    sorted lo nth 1 frac - *
    sorted hi nth frac *
    + ;

! ─── Ring buffer ─────────────────────────────────────────────────────────────

TUPLE: ring-buf capacity buf head ;

: <ring-buf> ( n -- ring )
    ring-buf new
        swap >>capacity
        V{ } clone >>buf
        0 >>head ;

: ring-push ( v ring -- )
    [ buf>> ] [ head>> ] [ capacity>> ] tri
    :> cap :> h :> b
    b length cap < [ b push ] [ v h cap mod b set-nth drop ] if
    dup head>> 1 + >>head drop ;

: ring-slice ( ring -- seq )
    buf>> >array ;

! ─── Snapshot ─────────────────────────────────────────────────────────────────

! Extract cpu_pct from a parsed JSON dict
: snap-cpu ( snap -- f ) "cpu_pct" swap at 0 or ;
: snap-load1 ( snap -- f )
    "load" swap at [ "one" swap at 0 or ] [ 0 ] if* ;
: snap-mem-pct ( snap -- f )
    "mem" swap at [
        [ "total_kb" swap at 0 or ]
        [ "available_kb" swap at 0 or ] bi
        :> avail :> total
        total 0 > [ total avail - total / 100 * ] [ 0 ] if
    ] [ 0 ] if* ;

! ─── Alert evaluation ─────────────────────────────────────────────────────────

SYMBOL: alert-state

alert-state [ H{ } clone ] initialize

: check-threshold ( name value warn crit -- )
    severity :> sev
    sev "ok" = not [
        "{ \"type\": \"alert\", \"name\": \"%s\", \"severity\": \"%s\", \"value\": %f }\n"
        swap swap swap sprintf print flush
    ] when drop ;

: evaluate-snapshot ( snap -- )
    dup snap-cpu   70.0 90.0 check-threshold "cpu_pct"   rot
    dup snap-mem-pct 80.0 95.0 check-threshold "mem_pct" rot
    snap-load1 8.0 16.0 check-threshold "load_one" rot
    3drop ;

! ─── Statistics report ────────────────────────────────────────────────────────

: report-stats ( ring -- )
    ring-slice :> xs
    xs length 0 > [
        xs mean*     :> mu
        xs stddev*   :> sd
        xs 50 percentile* :> p50
        xs 90 percentile* :> p90
        xs 99 percentile* :> p99
        "{ \"type\": \"stats\", \"mean\": %.2f, \"stddev\": %.2f, "
        "\"p50\": %.2f, \"p90\": %.2f, \"p99\": %.2f }\n"
        append mu sd p50 p90 p99 sprintf print flush
    ] when ;

! ─── Main loop ────────────────────────────────────────────────────────────────

: muninn-main ( -- )
    60 <ring-buf> :> cpu-ring
    0 :> line-count!

    [
        readln dup [
            utf8 decode-string
            [ json> ] [ drop f ] recover
            [
                dup evaluate-snapshot
                dup snap-cpu cpu-ring ring-push
                line-count 1 + line-count!
                line-count 30 mod 0 = [ cpu-ring report-stats ] when
            ] when*
            t
        ] [ drop f ] if
    ] loop ;

MAIN: muninn-main
