# sparkline

function macro_sparkline(args, n, values, i, minv, maxv, range, level, result)
{
    split(args, values, /[[:space:]]+/)

    n = 0
    for (i in values) {
        if (values[i] != "")
            values[++n] = values[i] + 0
    }

    if (n == 0)
        return ""

    minv = maxv = values[1]

    for (i = 2; i <= n; i++) {
        if (values[i] < minv) minv = values[i]
        if (values[i] > maxv) maxv = values[i]
    }

    range = maxv - minv

    result = ""

    for (i = 1; i <= n; i++) {

        if (range == 0) {
            level = 8
        } else {
            level = int(((values[i] - minv) / range) * 8 + 0.5)
        }

        if (level == 0)      result = result " "
        else if (level == 1) result = result "▁"
        else if (level == 2) result = result "▂"
        else if (level == 3) result = result "▃"
        else if (level == 4) result = result "▄"
        else if (level == 5) result = result "▅"
        else if (level == 6) result = result "▆"
        else if (level == 7) result = result "▇"
        else                 result = result "█"
    }

    result = "\033[38;5;252;48;5;236m" result "\033[0m"

    return result
}