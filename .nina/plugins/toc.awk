# TOC
{
    if ($0 ~ /^#{1,6} /) {
        match($0, /^#+/)
        level = RLENGTH
        text = substr($0, level + 2)
        indent = ""
        for (i = 1; i < level; i++) indent = indent "*"
        print indent "* " text
    }
}
