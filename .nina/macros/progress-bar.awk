# |

function macro_progress_bar(args,    n, parts, pct, bar_len, negative, half_units, full_units, has_half, remaining, i, segs, seg_count, bar) {
    n = split(args, parts, " ")

    pct = parts[1]
    sub(/%$/, "", pct)
    pct += 0

    bar_len = (n >= 2) ? parts[2] + 0 : 20
    if (bar_len <= 0) bar_len = 20

    negative = 0
    if (pct < 0) {
        negative = 1
        pct = -pct
    }

    if (pct > 100) pct = 100

    half_units = int((pct / 100) * bar_len * 2)
    full_units = int(half_units / 2)
    has_half = half_units % 2
    remaining = bar_len - full_units - has_half

    seg_count = 0
    for (i = 0; i < full_units; i++) segs[++seg_count] = "▓"
    if (has_half) segs[++seg_count] = "▒"
    for (i = 0; i < remaining; i++) segs[++seg_count] = "░"

    bar = ""
    if (negative) {
        for (i = seg_count; i >= 1; i--) bar = bar segs[i]
    } else {
        for (i = 1; i <= seg_count; i++) bar = bar segs[i]
    }

    return bar
}
