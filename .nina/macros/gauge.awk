# gauge
#
# Usage: {{gauge value [units] min low_error low_warn high_warn high_error max [units] [width]}}
#
# Renders a horizontal band gauge: a red/amber/green/amber/red bar with a
# marker (▲) at the current value's position, plus min/max embedded at
# each end and the value (+ units, if given) printed after the bar.
#
# `units` and `width` are both optional and detected by type, not
# position, so either of these calling styles works:
#
#   {{gauge 60 0 30 50 100 120 150 PSI}}
#   {{gauge 60 PSI 0 30 50 100 120 150}}
#
# Examples:
#
#   Reference case - units after the bounds:
#     {{gauge 60 0 30 50 100 120 150 PSI}}
#     -> 0[bar with ▲ in the green band]150 60 PSI
#
#   Same value, units placed right after the value instead:
#     {{gauge 60 PSI 0 30 50 100 120 150}}
#     -> identical output to the example above
#
#   Custom width (default is 20 if omitted, same convention as the
#   progress-bar macro):
#     {{gauge 60 0 30 50 100 120 150 PSI 30}}
#     -> same gauge, rendered 30 characters wide instead of 20
#
#   No low-end red/amber bands - set min, low_error, and low_warn equal:
#     {{gauge 60 0 0 0 100 120 150 PSI}}
#     -> bar starts directly in green, no red/amber on the low end
#
#   No high-end amber band - set high_warn and high_error equal:
#     {{gauge 60 0 30 50 120 120 150 PSI}}
#     -> green transitions straight to red on the high end, no amber
#
#   Backward-counting gauge (lower values are "worse"/higher on the bar):
#     {{gauge 30 150 120 100 50 30 0 PSI}}
#     -> bar runs right-to-left in value terms; bands and marker position
#        stay correct since position is computed from the value/min/max
#        ratio, not from numeric direction
#
#   No units, no custom width:
#     {{gauge 60 0 30 50 100 120 150}}
#     -> 0[bar]150 60   (no units suffix)

function gauge_pos(v, lo, hi, width,   span, p) {
    span = (v - lo) / (hi - lo) * width
    p = int(span + 0.5)
    if (p < 0) p = 0
    if (p > width) p = width
    return p
}

function macro_gauge(args   ,tok, argc, idx, units, width, \
                      value_str, min_str, low_err_str, low_warn_str, \
                      high_warn_str, high_err_str, max_str, t, \
                      value, min, low_err, low_warn, high_warn, high_err, max, \
                      p0, p1, p2, p3, p4, p5, n1, n2, n3, n4, n5, \
                      pos, bar, i, idx2, RED, AMBER, GREEN, RESET) {

    argc = split(args, tok, " ")
    idx = 1

    value_str = tok[idx]; idx++

    units = ""
    if (idx <= argc && tok[idx] !~ /^-?[0-9]+(\.[0-9]+)?$/) {
        units = tok[idx]
        idx++
    }

    min_str       = tok[idx]; idx++
    low_err_str   = tok[idx]; idx++
    low_warn_str  = tok[idx]; idx++
    high_warn_str = tok[idx]; idx++
    high_err_str  = tok[idx]; idx++
    max_str       = tok[idx]; idx++

    width = 20
    while (idx <= argc) {
        t = tok[idx]
        if (t ~ /^-?[0-9]+(\.[0-9]+)?$/) {
            width = t + 0
        } else {
            units = t
        }
        idx++
    }

    value     = value_str + 0
    min       = min_str + 0
    low_err   = low_err_str + 0
    low_warn  = low_warn_str + 0
    high_warn = high_warn_str + 0
    high_err  = high_err_str + 0
    max       = max_str + 0

    # Validate before doing any arithmetic - a non-numeric arg would
    # otherwise cause a fatal division-by-zero when max == min == 0.
    # Return a literal error string so the rest of the document keeps
    # rendering (the macro engine just substitutes this string in place
    # of the {{gauge}} call, the way it would for any other return value).
    if (argc < 8) {
        return "{{gauge: expected at least 8 arguments, got " argc "}}"
    }
    if (value_str !~ /^-?[0-9]+(\.[0-9]+)?$/ || \
        min_str   !~ /^-?[0-9]+(\.[0-9]+)?$/ || \
        max_str   !~ /^-?[0-9]+(\.[0-9]+)?$/) {
        return "{{gauge: non-numeric value, min, or max - usage: {{gauge value [units] min low_err low_warn high_warn high_err max [units] [width]}}}}"
    }
    if (max == min) {
        return "{{gauge: min and max must differ}}"
    }

    RED = "\033[48;5;124m"; AMBER = "\033[48;5;178m"; GREEN = "\033[48;5;70m"; RESET = "\033[0m"

    # Cumulative boundary positions first, then differences for band
    # widths - guarantees bands always sum to exactly `width` (rounding
    # each band independently can overshoot/undershoot by a char or two).
    p0 = gauge_pos(min,       min, max, width)
    p1 = gauge_pos(low_err,   min, max, width)
    p2 = gauge_pos(low_warn,  min, max, width)
    p3 = gauge_pos(high_warn, min, max, width)
    p4 = gauge_pos(high_err,  min, max, width)
    p5 = gauge_pos(max,       min, max, width)

    n1 = p1 - p0   # low red
    n2 = p2 - p1   # low amber
    n3 = p3 - p2   # green
    n4 = p4 - p3   # high amber
    n5 = p5 - p4   # high red

    pos = gauge_pos(value, min, max, width)
    if (pos >= width) pos = width - 1
    if (pos < 0) pos = 0

    bar = ""
    idx2 = 0

    for (i = 0; i < n1; i++) { bar = bar RED   ((idx2 == pos) ? "\xE2\x96\xB2" : " ") RESET; idx2++ }
    for (i = 0; i < n2; i++) { bar = bar AMBER ((idx2 == pos) ? "\xE2\x96\xB2" : " ") RESET; idx2++ }
    for (i = 0; i < n3; i++) { bar = bar GREEN ((idx2 == pos) ? "\xE2\x96\xB2" : " ") RESET; idx2++ }
    for (i = 0; i < n4; i++) { bar = bar AMBER ((idx2 == pos) ? "\xE2\x96\xB2" : " ") RESET; idx2++ }
    for (i = 0; i < n5; i++) { bar = bar RED   ((idx2 == pos) ? "\xE2\x96\xB2" : " ") RESET; idx2++ }

    return min_str bar max_str " " value_str (units == "" ? "" : " " units)
}
