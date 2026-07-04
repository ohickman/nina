# intro
# =====================================================
# A getting-started example plugin, written for someone
# who has never used AWK before. Every section below
# demonstrates one capability in isolation, in roughly
# the order a new plugin author would reach for them.
# Nothing here is clever on purpose - readability was
# chosen over brevity every time the two were in tension.
#
# Install with:  nina --plugin
# Use with:      <<intro>>
# =====================================================

# -----------------------------------------
# BEGIN runs once, before any of the article's text has
# been read. Anything that doesn't depend on the article's
# content - like its title - can be printed here.
# -----------------------------------------

BEGIN {
    print "The title of this article is: " plugin_current_title()
    print ""
    print "The first five lines this plugin received (typically the article's own header) are:"
}

# -----------------------------------------
# A plain AWK rule with no BEGIN/END keyword runs once for
# EVERY line of input - and the article being rendered is
# exactly what arrives as input here, one line at a time.
# NR is a built-in AWK variable: the number of the line
# currently being read. There's nothing to set up - $0
# (the line itself) and NR are simply already there.
#
# This is plain AWK, not anything plugin-specific - the
# same rule would work in any AWK script reading any file.
# -----------------------------------------

NR <= 5 {
    print "  " NR ": " $0
}

# -----------------------------------------
# END runs once, after every line of input has been read.
# Everything from here on doesn't depend on the article's
# content either, so - same as BEGIN - it could just as
# well have lived there. It's placed in END here only so
# the "five lines" section above prints before it, in the
# order a reader would expect.
# -----------------------------------------

END {
    print ""
    print "Current time: " plugin_now()
    print "Your terminal is " plugin_term_width() " columns wide right now."

    # -----------------------------------------
    # plugin_debug() writes to stderr, not to the article -
    # if you're viewing this in a terminal, the line below
    # appears there, never in the rendered text. This is the
    # tool to reach for while writing your own plugin: print
    # whatever you need to see, without it leaking into the
    # document the way an ordinary print() would.
    # -----------------------------------------

    plugin_debug("intro.awk ran successfully - this line only appears here, in your terminal's error output, never in the article itself.")

    print ""
    links = plugin_links(plugin_current_title())
    if (links == "")
        print "This article links to: (nothing - it has no outbound links)"
    else
        print "This article links to:\n" links

    # -----------------------------------------
    # Best practice for any plugin that wants the network:
    # check plugin_web_allowed() first, and have a sensible,
    # friendly fallback ready for when it's off. This check
    # is a courtesy, not the real enforcement - plugin_http_get()
    # refuses on its own regardless - but skipping it means
    # building a request that's just going to be thrown away.
    #
    # api.weather.gov is run by the US National Weather
    # Service (NOAA) - genuinely free, no key required, and
    # backed by a federal agency rather than a third-party
    # company, which is exactly the kind of thing likely to
    # still be running years from now. /alerts/active/count
    # is one of their simplest endpoints: no parameters, no
    # coordinates to look up, just a small JSON object back.
    # If this specific path ever stops working, check
    # https://www.weather.gov/documentation/services-web-api
    # for the current one - everything else about this
    # example (the permission check, the request, the two
    # outcomes below) stays the same regardless of the URL.
    # -----------------------------------------

    print ""
    if (plugin_web_allowed()) {
        data = plugin_http_get("https://api.weather.gov/alerts/active/count")
        if (data != "")
            print "Live data from api.weather.gov (active US weather alerts):\n" data
        else
            print "Tried to reach api.weather.gov, but the request failed or returned nothing."
    } else {
        print "Web requests are turned off (PLUGIN_PERMIT_WEB is not set to true in your config), so the live-data example above was skipped rather than attempted."
    }
}
