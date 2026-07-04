# days_to_go

function to_jdn(y, m, d) {
    return int((1461 * (y + 4800 + int((m - 14) / 12))) / 4) \
         + int((367 * (m - 2 - 12 * int((m - 14) / 12))) / 12) \
         - int((3 * int((y + 4900 + int((m - 14) / 12)) / 100)) / 4) \
         + d - 32075
}

function macro_days_to_go(args   ,today_parts, target_parts, today_jdn, target_jdn) {
    split(TODAY, today_parts, "-")
    split(args, target_parts, "-")
    today_jdn = to_jdn(today_parts[1] + 0, today_parts[2] + 0, today_parts[3] + 0)
    target_jdn = to_jdn(target_parts[1] + 0, target_parts[2] + 0, target_parts[3] + 0)
    return target_jdn - today_jdn
}
