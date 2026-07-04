# Backlinks
BEGIN {
    title = plugin_current_title()
    result = plugin_backlinks(title)
    if (result == "") {
        print "(no backlinks)"
    } else {
        n = split(result, lines, "\n")
        for (i = 1; i <= n; i++) print "* " lines[i]
    }
}
