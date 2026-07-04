# show_alert
BEGIN {
    title = plugin_args()
    body = plugin_read_article_body(title)
    if (body != "") print body
}
